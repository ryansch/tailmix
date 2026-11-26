package state

import "net"

// Location values for Location.Current. The empty string means the location
// is unknown.
const (
	LocationHome = "home"
	LocationAway = "away"
)

// Override values for Location.Override. The empty string means no override:
// routes follow the detected location.
const (
	OverrideRoutesOn  = "on"
	OverrideRoutesOff = "off"
)

// Location is a profile's opt-in location-aware route state. While the host
// is on one of HomeGateways, the profile's accept-all IP and DNS routes are
// suppressed.
type Location struct {
	Enabled bool `json:"enabled,omitempty"`
	// HomeGateways are default-gateway MAC addresses in
	// net.HardwareAddr.String() form.
	HomeGateways []string `json:"homeGateways,omitempty"`
	// Current is LocationHome, LocationAway or "" (unknown).
	Current string `json:"current,omitempty"`
	// Override is OverrideRoutesOn, OverrideRoutesOff or "" (none).
	Override string `json:"override,omitempty"`
}

// RoutesSuppressed reports whether the profile's accept-all IP and DNS routes
// are currently turned off by location awareness.
func (p Profile) RoutesSuppressed() bool {
	loc := p.Location
	if loc == nil || !loc.Enabled {
		return false
	}
	switch loc.Override {
	case OverrideRoutesOn:
		return false
	case OverrideRoutesOff:
		return true
	}
	return loc.Current == LocationHome
}

// EffectiveAcceptAllRoutes reports whether accept-all IP routes are in effect
// after applying location awareness.
func (p Profile) EffectiveAcceptAllRoutes() bool {
	return p.AcceptAllRoutes && !p.RoutesSuppressed()
}

// EffectiveAcceptAllDNSRoutes reports whether accept-all DNS routes are in
// effect after applying location awareness.
func (p Profile) EffectiveAcceptAllDNSRoutes() bool {
	return p.AcceptAllDNSRoutes && !p.RoutesSuppressed()
}

// NormalizeGateway parses a gateway MAC address and returns it in canonical
// net.HardwareAddr.String() form.
func NormalizeGateway(s string) (string, error) {
	mac, err := net.ParseMAC(s)
	if err != nil {
		return "", err
	}
	return mac.String(), nil
}

// Clone returns a deep copy of l, or nil if l is nil.
func (l *Location) Clone() *Location {
	if l == nil {
		return nil
	}
	c := *l
	c.HomeGateways = append([]string(nil), l.HomeGateways...)
	return &c
}

func normalizeLocation(l *Location) *Location {
	if l == nil {
		return nil
	}
	var gateways []string
	seen := map[string]bool{}
	for _, raw := range l.HomeGateways {
		gw, err := NormalizeGateway(raw)
		if err != nil || seen[gw] {
			continue
		}
		seen[gw] = true
		gateways = append(gateways, gw)
	}
	l.HomeGateways = gateways
	if !l.Enabled && len(l.HomeGateways) == 0 && l.Current == "" && l.Override == "" {
		return nil
	}
	return l
}
