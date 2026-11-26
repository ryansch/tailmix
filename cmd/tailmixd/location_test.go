package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/maisem/tailmix/controlapi"
	"github.com/maisem/tailmix/netlocation"
	tailmixprofile "github.com/maisem/tailmix/profile"
	"github.com/maisem/tailmix/state"
)

const (
	gatewayA = "aa:aa:aa:aa:aa:01"
	gatewayB = "bb:bb:bb:bb:bb:02"
)

var locationT0 = time.Date(2026, 11, 25, 12, 0, 0, 0, time.UTC)

// newLocationTestSupervisor returns a supervisor whose gateway source is
// supported and whose clock reads *now.
func newLocationTestSupervisor(t *testing.T, profiles ...state.Profile) (*supervisor, *time.Time) {
	t.Helper()
	st := lifecycleTestState()
	st.Profiles = profiles
	s := newLifecycleTestSupervisor(t, st)
	s.cfg.Gateways = func() ([]string, error) { return nil, nil }
	now := locationT0
	s.clock = func() time.Time { return now }
	return s, &now
}

func homeProfile() state.Profile {
	return state.Profile{
		ID: "p_home", Name: "home", StateDir: "profiles/home",
		AcceptAllRoutes: true, AcceptAllDNSRoutes: true,
	}
}

func wantAPIError(t *testing.T, err error, code string) {
	t.Helper()
	var apiErr *controlapi.Error
	if !errors.As(err, &apiErr) || apiErr.Code != code {
		t.Fatalf("error = %v, want code %q", err, code)
	}
}

func observe(t *testing.T, s *supervisor, seen []string, now time.Time) {
	t.Helper()
	if err := s.observeLocation(seen, now); err != nil {
		t.Fatalf("observeLocation(%v): %v", seen, err)
	}
}

func getProfile(t *testing.T, s *supervisor, name string) controlapi.Profile {
	t.Helper()
	got, err := s.GetProfile(context.Background(), name)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func wantLocation(t *testing.T, got controlapi.Profile, current string, routes bool) {
	t.Helper()
	if got.Location == nil || got.Location.Current != current || got.RoutesInEffect != routes {
		t.Fatalf("profile %s: location = %+v, routesInEffect = %v; want %s, %v",
			got.Name, got.Location, got.RoutesInEffect, current, routes)
	}
}

func savedLocation(t *testing.T, s *supervisor, profileID string) *state.Location {
	t.Helper()
	saved, err := s.store.Load()
	if err != nil {
		t.Fatal(err)
	}
	configured := profileByID(&saved, profileID)
	if configured == nil {
		t.Fatalf("profile %s missing from saved state", profileID)
	}
	return configured.Location
}

// enableAtHome turns location on for the home profile and marks gatewayA as
// its home network.
func enableAtHome(t *testing.T, s *supervisor, now time.Time) {
	t.Helper()
	ctx := context.Background()
	got, err := s.SetProfileLocation(ctx, "home", controlapi.SetLocationRequest{Enabled: true})
	if err != nil {
		t.Fatal(err)
	}
	if got.Location == nil || !got.Location.Supported || !got.Location.Enabled || got.Location.Current != "unknown" {
		t.Fatalf("enabled location = %+v", got.Location)
	}
	observe(t, s, []string{gatewayA}, now)
	got, err = s.MarkCurrentNetworkHome(ctx, "home")
	if err != nil {
		t.Fatal(err)
	}
	wantLocation(t, got, "home", false)
	if !slices.Equal(got.Location.HomeNetworks, []string{gatewayA}) || !got.Location.NetworkAvailable || !got.Location.OnHomeNetwork {
		t.Fatalf("home location = %+v", got.Location)
	}
}

func TestLocationHomeAwayPersists(t *testing.T) {
	s, now := newLocationTestSupervisor(t, homeProfile())
	enableAtHome(t, s, *now)
	if loc := savedLocation(t, s, "p_home"); loc == nil || loc.Current != state.LocationHome {
		t.Fatalf("saved location = %+v, want home", loc)
	}

	observe(t, s, []string{gatewayB}, locationT0)
	got := getProfile(t, s, "home")
	wantLocation(t, got, "home", false)
	if got.Location.OnHomeNetwork || !got.Location.NetworkAvailable {
		t.Fatalf("foreign network location = %+v", got.Location)
	}
	observe(t, s, []string{gatewayB}, locationT0.Add(60*time.Second))
	wantLocation(t, getProfile(t, s, "home"), "away", true)
	if loc := savedLocation(t, s, "p_home"); loc == nil || loc.Current != state.LocationAway {
		t.Fatalf("saved location = %+v, want away", loc)
	}
}

func TestLocationOverrideClearsOnChange(t *testing.T) {
	s, now := newLocationTestSupervisor(t, homeProfile())
	ctx := context.Background()
	enableAtHome(t, s, *now)
	observe(t, s, []string{gatewayB}, locationT0)
	observe(t, s, []string{gatewayB}, locationT0.Add(time.Minute))
	wantLocation(t, getProfile(t, s, "home"), "away", true)

	got, err := s.SetLocationOverride(ctx, "home", controlapi.SetLocationOverrideRequest{Routes: "off"})
	if err != nil {
		t.Fatal(err)
	}
	wantLocation(t, got, "away", false)
	if got.Location.Override != "off" || savedLocation(t, s, "p_home").Override != state.OverrideRoutesOff {
		t.Fatalf("override = %q, saved = %+v", got.Location.Override, savedLocation(t, s, "p_home"))
	}

	observe(t, s, []string{gatewayA}, locationT0.Add(2*time.Minute))
	got = getProfile(t, s, "home")
	wantLocation(t, got, "home", false)
	if got.Location.Override != "" || savedLocation(t, s, "p_home").Override != "" {
		t.Fatalf("override after location change = %q", got.Location.Override)
	}

	got, err = s.SetLocationOverride(ctx, "home", controlapi.SetLocationOverrideRequest{Routes: "on"})
	if err != nil {
		t.Fatal(err)
	}
	wantLocation(t, got, "home", true)
	observe(t, s, nil, locationT0.Add(3*time.Minute))
	got = getProfile(t, s, "home")
	wantLocation(t, got, "home", true)
	if got.Location.Override != "on" || got.Location.NetworkAvailable {
		t.Fatalf("override after outage = %+v", got.Location)
	}

	got, err = s.ClearLocationOverride(ctx, "home")
	if err != nil {
		t.Fatal(err)
	}
	wantLocation(t, got, "home", false)
	if got.Location.Override != "" {
		t.Fatalf("cleared override = %q", got.Location.Override)
	}
	if _, err := s.SetLocationOverride(ctx, "home", controlapi.SetLocationOverrideRequest{Routes: "maybe"}); err == nil {
		t.Fatal("override maybe succeeded")
	} else {
		wantAPIError(t, err, "invalid_request")
	}
}

func TestLocationOverrideOnRefusedWhenConfiguredOff(t *testing.T) {
	configured := homeProfile()
	configured.AcceptAllRoutes = false
	configured.AcceptAllDNSRoutes = false
	s, now := newLocationTestSupervisor(t, configured)
	enableAtHome(t, s, *now)
	observe(t, s, []string{gatewayB}, locationT0)
	observe(t, s, []string{gatewayB}, locationT0.Add(time.Minute))
	wantLocation(t, getProfile(t, s, "home"), "away", false)

	_, err := s.SetLocationOverride(context.Background(), "home", controlapi.SetLocationOverrideRequest{Routes: "on"})
	wantAPIError(t, err, "invalid_request")
	if loc := savedLocation(t, s, "p_home"); loc.Override != "" {
		t.Fatalf("refused override was saved: %+v", loc)
	}
}

func TestLocationFollowsRenameSkipsRemoved(t *testing.T) {
	s, now := newLocationTestSupervisor(t, homeProfile())
	ctx := context.Background()
	enableAtHome(t, s, *now)

	renamed := "house"
	if _, err := s.PatchProfile(ctx, "home", controlapi.PatchProfileRequest{Name: &renamed}); err != nil {
		t.Fatal(err)
	}
	got := getProfile(t, s, "house")
	wantLocation(t, got, "home", false)
	if !slices.Equal(got.Location.HomeNetworks, []string{gatewayA}) {
		t.Fatalf("renamed home networks = %v", got.Location.HomeNetworks)
	}
	observe(t, s, []string{gatewayB}, locationT0)
	observe(t, s, []string{gatewayB}, locationT0.Add(time.Minute))
	wantLocation(t, getProfile(t, s, "house"), "away", true)

	if _, err := s.RemoveProfile(ctx, "house", false); err != nil {
		t.Fatal(err)
	}
	observe(t, s, []string{gatewayA}, locationT0.Add(2*time.Minute))
	if loc := profileByID(&s.st, "p_home").Location; loc == nil || loc.Current != state.LocationAway {
		t.Fatalf("removed profile location = %+v, want away", loc)
	}
	_, err := s.MarkCurrentNetworkHome(ctx, "house")
	wantAPIError(t, err, "profile_not_found")
}

func TestMarkHomeNoNetwork(t *testing.T) {
	s, _ := newLocationTestSupervisor(t, homeProfile())
	ctx := context.Background()
	_, err := s.MarkCurrentNetworkHome(ctx, "home")
	wantAPIError(t, err, "invalid_request")

	if _, err := s.SetProfileLocation(ctx, "home", controlapi.SetLocationRequest{Enabled: true}); err != nil {
		t.Fatal(err)
	}
	observe(t, s, nil, locationT0)
	_, err = s.MarkCurrentNetworkHome(ctx, "home")
	wantAPIError(t, err, "no_network")
}

func TestForgetCurrentWaitsForGrace(t *testing.T) {
	s, now := newLocationTestSupervisor(t, homeProfile())
	ctx := context.Background()
	enableAtHome(t, s, *now)

	_, err := s.ForgetHomeNetwork(ctx, "home", "AA-BB-CC-DD-EE-FF")
	wantAPIError(t, err, "not_found")
	_, err = s.ForgetHomeNetwork(ctx, "home", "not-a-mac")
	wantAPIError(t, err, "invalid_request")

	got, err := s.ForgetHomeNetwork(ctx, "home", "current")
	if err != nil {
		t.Fatal(err)
	}
	wantLocation(t, got, "home", false)
	if len(got.Location.HomeNetworks) != 0 || got.Location.OnHomeNetwork {
		t.Fatalf("location after forget = %+v", got.Location)
	}
	observe(t, s, []string{gatewayA}, locationT0.Add(59*time.Second))
	wantLocation(t, getProfile(t, s, "home"), "home", false)
	observe(t, s, []string{gatewayA}, locationT0.Add(60*time.Second))
	wantLocation(t, getProfile(t, s, "home"), "away", true)
}

func TestForgetNamedHomeNetwork(t *testing.T) {
	s, now := newLocationTestSupervisor(t, homeProfile())
	enableAtHome(t, s, *now)
	got, err := s.ForgetHomeNetwork(context.Background(), "home", strings.ToUpper(gatewayA))
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Location.HomeNetworks) != 0 || len(savedLocation(t, s, "p_home").HomeGateways) != 0 {
		t.Fatalf("home networks after forget = %v", got.Location.HomeNetworks)
	}
}

func TestLocationDisableKeepsHomeNetworks(t *testing.T) {
	s, now := newLocationTestSupervisor(t, homeProfile())
	ctx := context.Background()
	enableAtHome(t, s, *now)
	if _, err := s.SetLocationOverride(ctx, "home", controlapi.SetLocationOverrideRequest{Routes: "on"}); err != nil {
		t.Fatal(err)
	}
	got, err := s.SetProfileLocation(ctx, "home", controlapi.SetLocationRequest{Enabled: false})
	if err != nil {
		t.Fatal(err)
	}
	if got.Location != nil || !got.RoutesInEffect {
		t.Fatalf("disabled location = %+v, routesInEffect = %v", got.Location, got.RoutesInEffect)
	}
	if loc := savedLocation(t, s, "p_home"); loc == nil || loc.Enabled || loc.Current != "" || loc.Override != "" ||
		!slices.Equal(loc.HomeGateways, []string{gatewayA}) {
		t.Fatalf("saved disabled location = %+v", loc)
	}
	got, err = s.SetProfileLocation(ctx, "home", controlapi.SetLocationRequest{Enabled: true})
	if err != nil {
		t.Fatal(err)
	}
	wantLocation(t, got, "home", false)
}

func TestLocationUnsupportedRejectsEnable(t *testing.T) {
	s, _ := newLocationTestSupervisor(t, homeProfile())
	s.cfg.Gateways = func() ([]string, error) { return nil, netlocation.ErrUnsupported }
	_, err := s.SetProfileLocation(context.Background(), "home", controlapi.SetLocationRequest{Enabled: true})
	wantAPIError(t, err, "unsupported")
	if _, err := s.SetProfileLocation(context.Background(), "home", controlapi.SetLocationRequest{Enabled: false}); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		s.runLocationLoop(context.Background())
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("location loop kept running on an unsupported platform")
	}
}

func TestLocationLoopObservesGateways(t *testing.T) {
	configured := homeProfile()
	configured.Location = &state.Location{Enabled: true, HomeGateways: []string{gatewayA}}
	s, _ := newLocationTestSupervisor(t, configured)
	s.clock = nil
	s.cfg.LocationPoll = time.Millisecond
	s.cfg.Gateways = func() ([]string, error) { return []string{gatewayA}, nil }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		s.runLocationLoop(ctx)
		close(done)
	}()
	defer func() {
		cancel()
		<-done
	}()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if got := getProfile(t, s, "home"); got.Location != nil && got.Location.Current == "home" {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("location loop never moved the profile home")
}

func TestObserveLocationAfterShutdownDoesNothing(t *testing.T) {
	configured := homeProfile()
	configured.Location = &state.Location{Enabled: true, HomeGateways: []string{gatewayA}}
	s, _ := newLocationTestSupervisor(t, configured)
	s.cancel()
	reconciled := s.reconcileErr
	s.reconcileErr = "sentinel"
	observe(t, s, []string{gatewayA}, locationT0)
	if loc := profileByID(&s.st, "p_home").Location; loc.Current != "" {
		t.Fatalf("location after shutdown = %+v, want unchanged", loc)
	}
	if loc := savedLocation(t, s, "p_home"); loc == nil || loc.Current != "" {
		t.Fatalf("saved location after shutdown = %+v, want unchanged", loc)
	}
	if s.reconcileErr != "sentinel" || len(s.seenGateways) != 0 {
		t.Fatalf("observeLocation ran after shutdown: reconcileErr = %q (was %q), seen = %v",
			s.reconcileErr, reconciled, s.seenGateways)
	}
}

func TestOperatorMayMarkAndOverride(t *testing.T) {
	s, _ := newLocationTestSupervisor(t, homeProfile())
	ctx := context.Background()
	if _, err := s.SetOperator(ctx, controlapi.SetOperatorRequest{UID: "501"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetProfileLocation(ctx, "home", controlapi.SetLocationRequest{Enabled: true}); err != nil {
		t.Fatal(err)
	}
	observe(t, s, []string{gatewayA}, locationT0)
	handler := authorizeMutations(controlapi.Handler(s), s.operatorUID)
	serve := func(method, path, body string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(method, path, strings.NewReader(body))
		request = request.WithContext(context.WithValue(request.Context(), peerUIDContextKey{}, "501"))
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response
	}
	for _, tc := range []struct{ method, path, body string }{
		{http.MethodPost, "/v1/profiles/by-name/home/location/home-networks/current", ""},
		{http.MethodPut, "/v1/profiles/by-name/home/location/override", `{"routes":"off"}`},
		{http.MethodDelete, "/v1/profiles/by-name/home/location/override", ""},
		{http.MethodDelete, "/v1/profiles/by-name/home/location/home-networks/current", ""},
	} {
		if response := serve(tc.method, tc.path, tc.body); response.Code != http.StatusOK {
			t.Fatalf("%s %s = %d %s", tc.method, tc.path, response.Code, response.Body.String())
		}
	}
	response := serve(http.MethodPut, "/v1/profiles/by-name/home/location", `{"enabled":false}`)
	var apiErr controlapi.Error
	if err := json.NewDecoder(response.Body).Decode(&apiErr); err != nil {
		t.Fatal(err)
	}
	if response.Code != http.StatusForbidden || apiErr.Code != "permission_denied" {
		t.Fatalf("operator PUT location = %d %+v", response.Code, apiErr)
	}
}

func TestLocationDisabledProfileUnchanged(t *testing.T) {
	ipOnly := state.Profile{ID: "p_ip", Name: "ip", StateDir: "profiles/ip", AcceptAllRoutes: true}
	dnsOnly := state.Profile{ID: "p_dns", Name: "dns", StateDir: "profiles/dns", AcceptAllDNSRoutes: true}
	none := state.Profile{ID: "p_none", Name: "none", StateDir: "profiles/none"}
	s, _ := newLocationTestSupervisor(t, ipOnly, dnsOnly, none)
	observe(t, s, []string{gatewayA}, locationT0)
	for name, want := range map[string]bool{"ip": true, "dns": true, "none": false} {
		got := getProfile(t, s, name)
		if got.RoutesInEffect != want || got.Location != nil {
			t.Fatalf("profile %s: routesInEffect = %v, location = %+v; want %v, nil", name, got.RoutesInEffect, got.Location, want)
		}
	}
}

// TestLocationObservedWhileDownAppliesOnUp checks that a location change seen
// while the daemon is down is saved and that bringing the daemon up applies
// it to the IP and DNS accept-all policy.
func TestLocationObservedWhileDownAppliesOnUp(t *testing.T) {
	office := state.Profile{
		ID: "p_office", Name: "office", StateDir: "profiles/office",
		AcceptAllRoutes: true, AcceptAllDNSRoutes: true,
	}
	s, _ := newLocationTestSupervisor(t, homeProfile(), office)
	enableAtHome(t, s, locationT0)
	observe(t, s, []string{gatewayB}, locationT0.Add(time.Second))
	observe(t, s, []string{gatewayB}, locationT0.Add(61*time.Second))
	wantLocation(t, getProfile(t, s, "home"), "away", true)

	ctx := context.Background()
	if _, err := s.SetDaemonUp(ctx, false); err != nil {
		t.Fatal(err)
	}
	observe(t, s, []string{gatewayA}, locationT0.Add(62*time.Second))
	if loc := savedLocation(t, s, "p_home"); loc == nil || loc.Current != state.LocationHome {
		t.Fatalf("saved location = %+v, want home", loc)
	}

	for _, id := range []string{"p_home", "p_office"} {
		engine := &lifecycleEngine{status: tailmixprofile.Status{ProfileID: id, BackendState: "Running"}}
		s.runtimes[id] = &managedProfile{runtime: runtimeProfile{Engine: engine}, cancel: func() {}}
	}
	if _, err := s.SetDaemonUp(ctx, true); err != nil {
		t.Fatal(err)
	}
	wantLocation(t, getProfile(t, s, "home"), "home", false)

	var ipNames, dnsNames []string
	for _, accept := range s.ipPolicy.Resource.AcceptAllProfiles {
		ipNames = append(ipNames, accept.ProfileName)
	}
	for _, accept := range s.dnsPolicy.Resource.AcceptAllProfiles {
		dnsNames = append(dnsNames, accept.ProfileName)
	}
	want := []string{"office"}
	if !slices.Equal(ipNames, want) || !slices.Equal(dnsNames, want) {
		t.Fatalf("accept-all profiles after up: IP %v, DNS %v; want %v", ipNames, dnsNames, want)
	}
}
