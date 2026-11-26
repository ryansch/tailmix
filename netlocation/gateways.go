package netlocation

import (
	"errors"
	"net"
	"net/netip"
	"slices"
)

// ErrUnsupported is returned by Gateways on platforms without network
// location detection.
var ErrUnsupported = errors.New("network location detection is not supported on this platform")

// defaultRoute is a default route (0.0.0.0/0 or ::/0) through a gateway.
// IPv6 link-local gateways carry their zone so they match neighbor entries.
type defaultRoute struct {
	IfIndex int
	Gateway netip.Addr
}

// selectGateways returns the link-layer addresses of the gateways of routes
// whose interface has a link-layer address, in net.HardwareAddr.String() form,
// sorted and de-duplicated. neighbors is keyed by route, because two interfaces
// can reach different routers at the same IP; routes missing from it are
// skipped. The result is never nil; empty means no usable network.
func selectGateways(routes []defaultRoute, hasLinkAddr func(ifIndex int) bool, neighbors map[defaultRoute]net.HardwareAddr) []string {
	macs := []string{}
	for _, r := range routes {
		if !hasLinkAddr(r.IfIndex) {
			continue
		}
		mac, ok := neighbors[r]
		if !ok || len(mac) == 0 {
			continue
		}
		macs = append(macs, mac.String())
	}
	slices.Sort(macs)
	return slices.Compact(macs)
}
