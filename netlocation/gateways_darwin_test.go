package netlocation

import (
	"net"
	"os"
	"slices"
	"syscall"
	"testing"
	"time"

	"golang.org/x/net/route"
)

// TestGatewaysLive reads the real routing table. It asserts only on the shape
// of the result and never prints the addresses it finds.
func TestGatewaysLive(t *testing.T) {
	got, err := Gateways()
	if err != nil {
		t.Fatalf("Gateways() error: %v", err)
	}
	if len(got) == 0 {
		if os.Getenv("CI") != "" {
			t.Skip("no default gateway with a resolved link-layer address on this CI host")
		}
		t.Fatal("Gateways() returned no gateways; this test expects a host connected to a network")
	}
	for i, s := range got {
		mac, err := net.ParseMAC(s)
		if err != nil {
			t.Errorf("entry %d is not a MAC address", i)
			continue
		}
		if slices.Equal(mac, make(net.HardwareAddr, len(mac))) {
			t.Errorf("entry %d is an all-zero address", i)
		}
		if mac.String() != s {
			t.Errorf("entry %d is not in normalized form", i)
		}
	}
}

// fakeRouteSocket serves marshaled routing messages to readNeighborReply and
// advances a fake clock by step on every read.
type fakeRouteSocket struct {
	t     *testing.T
	msgs  func(read int) *route.RouteMessage
	clock time.Time
	step  time.Duration
	reads int
}

func (s *fakeRouteSocket) now() time.Time { return s.clock }

func (s *fakeRouteSocket) read(b []byte) (int, error) {
	s.reads++
	s.clock = s.clock.Add(s.step)
	m, err := s.msgs(s.reads).Marshal()
	if err != nil {
		s.t.Fatalf("marshal: %v", err)
	}
	return copy(b, m), nil
}

func unrelatedRouteMessage() *route.RouteMessage {
	return &route.RouteMessage{
		Version: syscall.RTM_VERSION,
		Type:    syscall.RTM_ADD,
		ID:      1,
		Seq:     99,
		Addrs: []route.Addr{
			syscall.RTAX_DST:     &route.Inet4Addr{IP: [4]byte{10, 0, 0, 0}},
			syscall.RTAX_GATEWAY: &route.Inet4Addr{IP: [4]byte{10, 0, 0, 1}},
		},
	}
}

// TestReadNeighborReplyGivesUpAmidUnrelatedMessages feeds an endless stream of
// other processes' routing messages and asserts the lookup ends with an error
// once the overall deadline passes instead of reading forever.
func TestReadNeighborReplyGivesUpAmidUnrelatedMessages(t *testing.T) {
	s := &fakeRouteSocket{
		t:     t,
		msgs:  func(int) *route.RouteMessage { return unrelatedRouteMessage() },
		clock: time.Unix(0, 0),
		step:  100 * time.Millisecond,
	}
	mac, err := readNeighborReply(s.read, s.now, 42, 7)
	if err == nil {
		t.Fatalf("readNeighborReply() = %v, nil; want a timeout error", mac)
	}
	if want := int(neighborReplyTimeout / s.step); s.reads != want {
		t.Errorf("reads = %d, want %d", s.reads, want)
	}
}

// TestReadNeighborReplySkipsUnrelatedMessages asserts the reply is still found
// behind unrelated messages within the deadline.
func TestReadNeighborReplySkipsUnrelatedMessages(t *testing.T) {
	want := net.HardwareAddr{0x02, 0, 0, 0, 0, 1}
	s := &fakeRouteSocket{
		t: t,
		msgs: func(read int) *route.RouteMessage {
			if read < 3 {
				return unrelatedRouteMessage()
			}
			return &route.RouteMessage{
				Version: syscall.RTM_VERSION,
				Type:    syscall.RTM_GET,
				Flags:   syscall.RTF_LLINFO,
				ID:      42,
				Seq:     7,
				Addrs: []route.Addr{
					syscall.RTAX_DST:     &route.Inet4Addr{IP: [4]byte{192, 0, 2, 1}},
					syscall.RTAX_GATEWAY: &route.LinkAddr{Addr: want},
				},
			}
		},
		clock: time.Unix(0, 0),
		step:  100 * time.Millisecond,
	}
	got, err := readNeighborReply(s.read, s.now, 42, 7)
	if err != nil {
		t.Fatalf("readNeighborReply() error: %v", err)
	}
	if got.String() != want.String() {
		t.Errorf("readNeighborReply() = %v, want %v", got, want)
	}
}
