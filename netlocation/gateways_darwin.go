package netlocation

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strconv"
	"syscall"
	"time"

	"golang.org/x/net/route"
)

// Gateways returns the MACs of the default gateways of active interfaces that
// have a link-layer address, normalized, sorted, de-duplicated. Empty = no
// network.
//
// Default routes come from the routing table dump. Each gateway's link-layer
// address is then looked up with an RTM_GET on a routing socket, scoped to the
// route's interface: unprivileged processes on recent macOS see no IPv4 ARP
// entries in the table dump, but RTM_GET still returns them.
func Gateways() ([]string, error) {
	rib, err := route.FetchRIB(syscall.AF_UNSPEC, route.RIBTypeRoute, 0)
	if err != nil {
		return nil, fmt.Errorf("read routing table: %w", err)
	}
	msgs, err := route.ParseRIB(route.RIBTypeRoute, rib)
	if err != nil {
		return nil, fmt.Errorf("parse routing table: %w", err)
	}
	routes := defaultRoutes(msgs)

	hasLinkAddr := func(ifIndex int) bool {
		ifi, err := net.InterfaceByIndex(ifIndex)
		return err == nil && ifi.Flags&net.FlagUp != 0 && len(ifi.HardwareAddr) > 0
	}

	var linked []defaultRoute
	for _, r := range routes {
		if hasLinkAddr(r.IfIndex) {
			linked = append(linked, r)
		}
	}
	neighbors, err := lookupNeighbors(linked)
	if err != nil {
		return nil, err
	}
	return selectGateways(routes, hasLinkAddr, neighbors), nil
}

// defaultRoutes extracts the 0.0.0.0/0 and ::/0 routes through a gateway.
func defaultRoutes(msgs []route.Message) []defaultRoute {
	var routes []defaultRoute
	for _, m := range msgs {
		rm, ok := m.(*route.RouteMessage)
		if !ok || rm.Flags&syscall.RTF_GATEWAY == 0 || rm.Flags&syscall.RTF_HOST != 0 {
			continue
		}
		if len(rm.Addrs) <= syscall.RTAX_GATEWAY || !isUnspecified(rm.Addrs[syscall.RTAX_DST]) {
			continue
		}
		if len(rm.Addrs) > syscall.RTAX_NETMASK && rm.Addrs[syscall.RTAX_NETMASK] != nil && !isUnspecified(rm.Addrs[syscall.RTAX_NETMASK]) {
			continue
		}
		gw, ok := inetAddr(rm.Addrs[syscall.RTAX_GATEWAY])
		if !ok {
			continue
		}
		routes = append(routes, defaultRoute{IfIndex: rm.Index, Gateway: gw})
	}
	return routes
}

// isUnspecified reports whether a is the all-zeros IPv4 or IPv6 address.
func isUnspecified(a route.Addr) bool {
	switch a := a.(type) {
	case *route.Inet4Addr:
		return a.IP == [4]byte{}
	case *route.Inet6Addr:
		return a.IP == [16]byte{}
	}
	return false
}

// inetAddr converts a routing-message address to a netip.Addr, carrying the
// zone of IPv6 addresses as the interface index.
func inetAddr(a route.Addr) (netip.Addr, bool) {
	switch a := a.(type) {
	case *route.Inet4Addr:
		return netip.AddrFrom4(a.IP), true
	case *route.Inet6Addr:
		ip := netip.AddrFrom16(a.IP)
		if a.ZoneID != 0 {
			ip = ip.WithZone(strconv.Itoa(a.ZoneID))
		}
		return ip, true
	}
	return netip.Addr{}, false
}

// routeAddr is the inverse of inetAddr.
func routeAddr(ip netip.Addr) route.Addr {
	if ip.Is4() {
		return &route.Inet4Addr{IP: ip.As4()}
	}
	zone, _ := strconv.Atoi(ip.Zone())
	return &route.Inet6Addr{IP: ip.As16(), ZoneID: zone}
}

// lookupNeighbors resolves each route's gateway to its link-layer address.
// Routes whose gateway the kernel has not resolved, or whose lookup fails, are
// left out, so one bad route cannot disable detection. Only failing to open or
// configure the routing socket is an error.
func lookupNeighbors(routes []defaultRoute) (map[defaultRoute]net.HardwareAddr, error) {
	neighbors := make(map[defaultRoute]net.HardwareAddr)
	if len(routes) == 0 {
		return neighbors, nil
	}
	fd, err := syscall.Socket(syscall.AF_ROUTE, syscall.SOCK_RAW, syscall.AF_UNSPEC)
	if err != nil {
		return nil, fmt.Errorf("open routing socket: %w", os.NewSyscallError("socket", err))
	}
	defer syscall.Close(fd)
	tv := syscall.Timeval{Sec: 1}
	if err := syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv); err != nil {
		return nil, fmt.Errorf("set routing socket timeout: %w", os.NewSyscallError("setsockopt", err))
	}
	pid := uintptr(os.Getpid())
	for i, r := range routes {
		mac, err := getNeighbor(fd, pid, i+1, r)
		if err != nil {
			continue // e.g. a timed-out or rejected lookup; skip this route
		}
		if len(mac) > 0 {
			neighbors[r] = mac
		}
	}
	return neighbors, nil
}

// getNeighbor sends an RTM_GET for r's gateway, scoped to r's interface, and
// returns the link-layer address of the resulting neighbor entry, or nil when
// the kernel has none.
func getNeighbor(fd int, pid uintptr, seq int, r defaultRoute) (net.HardwareAddr, error) {
	req := &route.RouteMessage{
		Version: syscall.RTM_VERSION,
		Type:    syscall.RTM_GET,
		Flags:   syscall.RTF_IFSCOPE,
		Index:   r.IfIndex,
		ID:      pid,
		Seq:     seq,
		Addrs:   []route.Addr{syscall.RTAX_DST: routeAddr(r.Gateway)},
	}
	b, err := req.Marshal()
	if err != nil {
		return nil, fmt.Errorf("build route lookup: %w", err)
	}
	if _, err := syscall.Write(fd, b); err != nil {
		if errors.Is(err, syscall.ESRCH) {
			return nil, nil
		}
		return nil, fmt.Errorf("route lookup: %w", os.NewSyscallError("write", err))
	}
	read := func(b []byte) (int, error) { return syscall.Read(fd, b) }
	return readNeighborReply(read, time.Now, pid, seq)
}

// neighborReplyTimeout bounds the whole wait for an RTM_GET reply. The
// socket's receive timeout only bounds each read, and the routing socket also
// carries every unrelated routing message on the system, so during sustained
// route churn a lost reply would otherwise keep the loop reading forever.
const neighborReplyTimeout = 2 * time.Second

// readNeighborReply reads routing messages until the reply to the RTM_GET
// identified by pid and seq arrives, and returns its link-layer address, or
// nil when the kernel has none. It gives up with an error once
// neighborReplyTimeout has passed.
func readNeighborReply(read func([]byte) (int, error), now func() time.Time, pid uintptr, seq int) (net.HardwareAddr, error) {
	deadline := now().Add(neighborReplyTimeout)
	buf := make([]byte, 4096)
	for {
		if !now().Before(deadline) {
			return nil, errors.New("route lookup: timed out waiting for reply")
		}
		n, err := read(buf)
		if err != nil {
			if errors.Is(err, syscall.EINTR) {
				continue
			}
			return nil, fmt.Errorf("route lookup: %w", os.NewSyscallError("read", err))
		}
		msgs, err := route.ParseRIB(route.RIBTypeRoute, buf[:n])
		if err != nil || len(msgs) == 0 {
			continue // not a message we can parse; not our reply
		}
		rm, ok := msgs[0].(*route.RouteMessage)
		if !ok || rm.Type != syscall.RTM_GET || rm.ID != pid || rm.Seq != seq {
			continue
		}
		if rm.Err != nil || rm.Flags&syscall.RTF_LLINFO == 0 || len(rm.Addrs) <= syscall.RTAX_GATEWAY {
			return nil, nil
		}
		la, ok := rm.Addrs[syscall.RTAX_GATEWAY].(*route.LinkAddr)
		if !ok || len(la.Addr) == 0 {
			return nil, nil
		}
		return net.HardwareAddr(la.Addr), nil
	}
}
