package netlocation

import (
	"net"
	"net/netip"
	"slices"
	"testing"
)

func mustMAC(t *testing.T, s string) net.HardwareAddr {
	t.Helper()
	mac, err := net.ParseMAC(s)
	if err != nil {
		t.Fatal(err)
	}
	return mac
}

func TestSelectGateways(t *testing.T) {
	const (
		en0  = 4
		en1  = 5
		utun = 20
	)
	linked := func(ifIndex int) bool { return ifIndex == en0 || ifIndex == en1 }
	router := netip.MustParseAddr("192.0.2.1")
	router2 := netip.MustParseAddr("192.0.2.2")
	other := netip.MustParseAddr("198.51.100.1")
	tunnelPeer := netip.MustParseAddr("fe80::1%20")

	en0Router := defaultRoute{IfIndex: en0, Gateway: router}
	en1Router := defaultRoute{IfIndex: en1, Gateway: router}
	en1Router2 := defaultRoute{IfIndex: en1, Gateway: router2}
	en1Other := defaultRoute{IfIndex: en1, Gateway: other}
	utunPeer := defaultRoute{IfIndex: utun, Gateway: tunnelPeer}

	tests := []struct {
		name      string
		routes    []defaultRoute
		neighbors map[defaultRoute]net.HardwareAddr
		want      []string
	}{
		{
			name:      "ipv4 default route with neighbor",
			routes:    []defaultRoute{en0Router},
			neighbors: map[defaultRoute]net.HardwareAddr{en0Router: mustMAC(t, "AA:BB:CC:00:00:01")},
			want:      []string{"aa:bb:cc:00:00:01"},
		},
		{
			name:   "two interfaces reaching the same router are deduplicated",
			routes: []defaultRoute{en0Router, en1Router2},
			neighbors: map[defaultRoute]net.HardwareAddr{
				en0Router:  mustMAC(t, "aa:bb:cc:00:00:01"),
				en1Router2: mustMAC(t, "aa:bb:cc:00:00:01"),
			},
			want: []string{"aa:bb:cc:00:00:01"},
		},
		{
			name:   "same gateway IP on two interfaces resolving to different routers",
			routes: []defaultRoute{en0Router, en1Router},
			neighbors: map[defaultRoute]net.HardwareAddr{
				en0Router: mustMAC(t, "aa:bb:cc:00:00:01"),
				en1Router: mustMAC(t, "aa:bb:cc:00:00:02"),
			},
			want: []string{"aa:bb:cc:00:00:01", "aa:bb:cc:00:00:02"},
		},
		{
			name:      "default route on an interface without a link-layer address is ignored",
			routes:    []defaultRoute{utunPeer},
			neighbors: map[defaultRoute]net.HardwareAddr{utunPeer: mustMAC(t, "aa:bb:cc:00:00:09")},
			want:      []string{},
		},
		{
			name:      "gateway without a neighbor entry is skipped",
			routes:    []defaultRoute{en0Router, en1Other},
			neighbors: map[defaultRoute]net.HardwareAddr{en0Router: mustMAC(t, "aa:bb:cc:00:00:01")},
			want:      []string{"aa:bb:cc:00:00:01"},
		},
		{
			name:   "output is sorted",
			routes: []defaultRoute{en0Router, en1Other},
			neighbors: map[defaultRoute]net.HardwareAddr{
				en0Router: mustMAC(t, "aa:bb:cc:00:00:02"),
				en1Other:  mustMAC(t, "aa:bb:cc:00:00:01"),
			},
			want: []string{"aa:bb:cc:00:00:01", "aa:bb:cc:00:00:02"},
		},
		{
			name:      "no routes means no network",
			routes:    nil,
			neighbors: nil,
			want:      []string{},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := selectGateways(tt.routes, linked, tt.neighbors)
			if got == nil || !slices.Equal(got, tt.want) {
				t.Fatalf("selectGateways() = %#v, want %#v", got, tt.want)
			}
		})
	}
}
