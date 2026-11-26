package state

import (
	"path/filepath"
	"reflect"
	"testing"
)

func TestRoutesSuppressed(t *testing.T) {
	tests := []struct {
		name     string
		location *Location
		want     bool
	}{
		{name: "nil location", location: nil, want: false},
		{name: "disabled at home", location: &Location{Current: LocationHome}, want: false},
		{name: "enabled at home", location: &Location{Enabled: true, Current: LocationHome}, want: true},
		{name: "enabled away", location: &Location{Enabled: true, Current: LocationAway}, want: false},
		{name: "enabled unknown", location: &Location{Enabled: true}, want: false},
		{name: "away with override off", location: &Location{Enabled: true, Current: LocationAway, Override: OverrideRoutesOff}, want: true},
		{name: "home with override on", location: &Location{Enabled: true, Current: LocationHome, Override: OverrideRoutesOn}, want: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := Profile{ID: "work", Location: tt.location}
			if got := p.RoutesSuppressed(); got != tt.want {
				t.Fatalf("RoutesSuppressed() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestEffectiveAcceptAll(t *testing.T) {
	p := Profile{
		ID:                 "work",
		AcceptAllRoutes:    true,
		AcceptAllDNSRoutes: false,
		Location:           &Location{Enabled: true, Current: LocationHome},
	}
	if p.EffectiveAcceptAllRoutes() {
		t.Fatal("EffectiveAcceptAllRoutes() at home = true, want false")
	}
	if p.EffectiveAcceptAllDNSRoutes() {
		t.Fatal("EffectiveAcceptAllDNSRoutes() at home = true, want false")
	}

	p.Location.Current = LocationAway
	if !p.EffectiveAcceptAllRoutes() {
		t.Fatal("EffectiveAcceptAllRoutes() away = false, want true")
	}
	if p.EffectiveAcceptAllDNSRoutes() {
		t.Fatal("EffectiveAcceptAllDNSRoutes() away = true, want false")
	}
}

func TestNormalizeGateway(t *testing.T) {
	got, err := NormalizeGateway("AA:BB:CC:DD:EE:0F")
	if err != nil {
		t.Fatal(err)
	}
	if want := "aa:bb:cc:dd:ee:0f"; got != want {
		t.Fatalf("NormalizeGateway() = %q, want %q", got, want)
	}
	if _, err := NormalizeGateway("bogus"); err == nil {
		t.Fatal("NormalizeGateway(\"bogus\") succeeded, want error")
	}
}

func TestNormalizeLocationGateways(t *testing.T) {
	st := State{Profiles: []Profile{
		{
			ID: "home",
			Location: &Location{
				Enabled:      true,
				HomeGateways: []string{"AA:BB:CC:DD:EE:0F", "bogus", "11:22:33:44:55:66", "aa:bb:cc:dd:ee:0f"},
			},
		},
		{ID: "empty", Location: &Location{}},
	}}
	Normalize(&st)
	want := []string{"aa:bb:cc:dd:ee:0f", "11:22:33:44:55:66"}
	if got := st.Profiles[1].Location.HomeGateways; !reflect.DeepEqual(got, want) {
		t.Fatalf("HomeGateways = %q, want %q", got, want)
	}
	if st.Profiles[0].ID != "empty" || st.Profiles[0].Location != nil {
		t.Fatalf("zero Location was not dropped: %+v", st.Profiles[0].Location)
	}
}

func TestStoreRoundTripPreservesLocation(t *testing.T) {
	store := NewJSONStore(filepath.Join(t.TempDir(), "state.json"))
	want := Location{
		Enabled:      true,
		HomeGateways: []string{"aa:bb:cc:dd:ee:0f", "11:22:33:44:55:66"},
		Current:      LocationHome,
		Override:     OverrideRoutesOn,
	}
	loc := want
	loc.HomeGateways = append([]string(nil), want.HomeGateways...)
	st := State{
		SyntheticPool: "100.127.0.0/24",
		Profiles:      []Profile{{ID: "work", StateDir: "profiles/work", Location: &loc}},
	}
	if err := store.Save(st); err != nil {
		t.Fatal(err)
	}
	got, err := store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if got.Profiles[0].Location == nil || !reflect.DeepEqual(*got.Profiles[0].Location, want) {
		t.Fatalf("location did not round trip: got %+v want %+v", got.Profiles[0].Location, want)
	}
}
