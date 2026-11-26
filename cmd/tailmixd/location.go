package main

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/maisem/tailmix/controlapi"
	"github.com/maisem/tailmix/netlocation"
	"github.com/maisem/tailmix/state"
)

var _ controlapi.LocationBackend = (*supervisor)(nil)

const (
	defaultLocationPoll  = 5 * time.Second
	defaultLocationGrace = 60 * time.Second
	minLocationGrace     = 10 * time.Second
	maxLocationGrace     = 10 * time.Minute
)

// validateLocationGrace checks the -location-grace flag value.
func validateLocationGrace(grace time.Duration) error {
	if grace < minLocationGrace || grace > maxLocationGrace {
		return fmt.Errorf("invalid -location-grace %v; want between %v and %v", grace, minLocationGrace, maxLocationGrace)
	}
	return nil
}

func (s *supervisor) gatewaySource() func() ([]string, error) {
	if s.cfg.Gateways != nil {
		return s.cfg.Gateways
	}
	return netlocation.Gateways
}

func (s *supervisor) now() time.Time {
	if s.clock != nil {
		return s.clock()
	}
	return time.Now()
}

// locationSupported reports whether the gateway source can detect the
// network. The first call probes the source; it must not be made with s.mu
// held, because a lookup can take about a second per default route.
func (s *supervisor) locationSupported() bool {
	s.locationProbe.Do(func() {
		if _, err := s.gatewaySource()(); errors.Is(err, netlocation.ErrUnsupported) {
			s.locationUnsupported.Store(true)
		}
	})
	return !s.locationUnsupported.Load()
}

// runLocationLoop polls the default gateways and applies the resulting
// per-profile locations until ctx ends. It stops quietly on platforms without
// detection.
func (s *supervisor) runLocationLoop(ctx context.Context) {
	if !s.locationSupported() {
		return
	}
	poll := s.cfg.LocationPoll
	if poll <= 0 {
		poll = defaultLocationPoll
	}
	gateways := s.gatewaySource()
	ticker := time.NewTicker(poll)
	defer ticker.Stop()
	failing := false
	for {
		// Lookups happen without s.mu; observeLocation takes it.
		seen, err := gateways()
		switch {
		case errors.Is(err, netlocation.ErrUnsupported):
			s.locationUnsupported.Store(true)
			return
		case err != nil:
			// Treat the tick as "no network". The error may name an
			// interface or address, so it is not logged.
			if !failing {
				fmt.Fprintln(s.cfg.Stderr, "network location: gateway lookup failed; treating as no network")
			}
			failing = true
			seen = nil
		default:
			failing = false
		}
		if ctx.Err() != nil {
			return
		}
		_ = s.observeLocation(seen, s.now())
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// observeLocation records the gateways seen now and moves every opted-in
// profile to the location the tracker reports. Location changes are saved and
// then applied by reconciling, unless the daemon is down.
func (s *supervisor) observeLocation(seen []string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ctx != nil && s.ctx.Err() != nil {
		// close() may have torn the daemon down while this waited for mu.
		return nil
	}
	s.seenGateways = append([]string(nil), seen...)
	next := cloneState(s.st)
	var changed []string
	for i := range next.Profiles {
		if s.advanceLocationLocked(&next.Profiles[i], now) {
			changed = append(changed, next.Profiles[i].ID)
		}
	}
	if len(changed) == 0 {
		return nil
	}
	if err := s.commitLocationLocked(next, changed); err != nil {
		fmt.Fprintf(s.cfg.Stderr, "network location: %v\n", err)
		return err
	}
	return nil
}

// advanceLocationLocked moves configured to the location the tracker reports
// for the gateways seen now, ending any override the change ends. It reports
// whether the location changed. Removed profiles and profiles without location
// enabled are left alone.
func (s *supervisor) advanceLocationLocked(configured *state.Profile, now time.Time) bool {
	loc := configured.Location
	if configured.Removed || loc == nil || !loc.Enabled {
		return false
	}
	next := s.locationTracker.Next(configured.ID, loc.Current, loc.HomeGateways, s.seenGateways, now)
	if next == loc.Current {
		return false
	}
	if netlocation.ClearsOverride(loc.Current, next) {
		loc.Override = ""
	}
	loc.Current = next
	return true
}

// commitLocationLocked saves next, logs the location of each profile in
// changed, and reconciles unless the daemon is down. A failed reconcile keeps
// the saved location; reconcileLocked records the error.
func (s *supervisor) commitLocationLocked(next state.State, changed []string) error {
	state.Normalize(&next)
	if err := s.store.Save(next); err != nil {
		return fmt.Errorf("save location: %w", err)
	}
	s.st = next
	for _, id := range changed {
		configured := profileByID(&s.st, id)
		if configured == nil || configured.Location == nil {
			continue
		}
		routes := "off"
		if routesInEffect(*configured) {
			routes = "on"
		}
		fmt.Fprintf(s.cfg.Stderr, "profile %s: location %s, routes %s\n",
			profileName(*configured), configured.Location.Current, routes)
	}
	if s.st.Down {
		return nil
	}
	if err := s.reconcileLocked(); err != nil {
		return controlapi.NewError("reconcile_failed", "%v", err)
	}
	return nil
}

// commitProfileLocationLocked commits next after an API change to profileID
// and returns that profile's projection.
func (s *supervisor) commitProfileLocationLocked(next state.State, profileID string, advanced bool) (controlapi.Profile, error) {
	var changed []string
	if advanced {
		changed = []string{profileID}
	}
	if err := s.commitLocationLocked(next, changed); err != nil {
		return controlapi.Profile{}, err
	}
	configured := profileByID(&s.st, profileID)
	if configured == nil {
		return controlapi.Profile{}, controlapi.NewError("profile_not_found", "profile disappeared")
	}
	return s.projectProfileLocked(*configured), nil
}

// locationProfile returns the named, non-removed profile in st.
func locationProfile(st *state.State, name string) (*state.Profile, error) {
	configured, err := profileByName(st, name)
	if err != nil {
		return nil, err
	}
	if configured.Removed {
		return nil, controlapi.NewError("profile_not_found", "profile %q is removed", name)
	}
	return configured, nil
}

// enabledLocation returns configured's location, or invalid_request when
// location is not enabled for it.
func enabledLocation(configured *state.Profile) (*state.Location, error) {
	if configured.Location == nil || !configured.Location.Enabled {
		return nil, controlapi.NewError("invalid_request", "location is not enabled for profile %q", profileName(*configured))
	}
	return configured.Location, nil
}

func (s *supervisor) SetProfileLocation(_ context.Context, name string, request controlapi.SetLocationRequest) (controlapi.Profile, error) {
	supported := s.locationSupported()
	s.mu.Lock()
	defer s.mu.Unlock()
	next := cloneState(s.st)
	configured, err := locationProfile(&next, name)
	if err != nil {
		return controlapi.Profile{}, err
	}
	if request.Enabled {
		if !supported {
			return controlapi.Profile{}, controlapi.NewError("unsupported", "%v", netlocation.ErrUnsupported)
		}
		if configured.Location == nil {
			configured.Location = &state.Location{}
		}
		configured.Location.Enabled = true
	} else {
		// Keep the home networks so turning location back on restores them.
		if loc := configured.Location; loc != nil {
			loc.Enabled = false
			loc.Current = ""
			loc.Override = ""
		}
		s.locationTracker.Forget(configured.ID)
	}
	advanced := s.advanceLocationLocked(configured, s.now())
	return s.commitProfileLocationLocked(next, configured.ID, advanced)
}

func (s *supervisor) MarkCurrentNetworkHome(_ context.Context, name string) (controlapi.Profile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := cloneState(s.st)
	configured, err := locationProfile(&next, name)
	if err != nil {
		return controlapi.Profile{}, err
	}
	loc, err := enabledLocation(configured)
	if err != nil {
		return controlapi.Profile{}, err
	}
	if len(s.seenGateways) == 0 {
		return controlapi.Profile{}, controlapi.NewError("no_network", "no network gateway is visible")
	}
	for _, gw := range s.seenGateways {
		if !slices.Contains(loc.HomeGateways, gw) {
			loc.HomeGateways = append(loc.HomeGateways, gw)
		}
	}
	advanced := s.advanceLocationLocked(configured, s.now())
	return s.commitProfileLocationLocked(next, configured.ID, advanced)
}

func (s *supervisor) ForgetHomeNetwork(_ context.Context, name, gateway string) (controlapi.Profile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := cloneState(s.st)
	configured, err := locationProfile(&next, name)
	if err != nil {
		return controlapi.Profile{}, err
	}
	var forget []string
	if gateway == "current" {
		forget = s.seenGateways
	} else {
		normalized, err := state.NormalizeGateway(gateway)
		if err != nil {
			return controlapi.Profile{}, controlapi.NewError("invalid_request", "invalid gateway address")
		}
		if configured.Location == nil || !slices.Contains(configured.Location.HomeGateways, normalized) {
			return controlapi.Profile{}, controlapi.NewError("not_found", "profile %q has no such home network", name)
		}
		forget = []string{normalized}
	}
	if loc := configured.Location; loc != nil {
		loc.HomeGateways = slices.DeleteFunc(loc.HomeGateways, func(gw string) bool {
			return slices.Contains(forget, gw)
		})
	}
	advanced := s.advanceLocationLocked(configured, s.now())
	return s.commitProfileLocationLocked(next, configured.ID, advanced)
}

func (s *supervisor) SetLocationOverride(_ context.Context, name string, request controlapi.SetLocationOverrideRequest) (controlapi.Profile, error) {
	if request.Routes != state.OverrideRoutesOn && request.Routes != state.OverrideRoutesOff {
		return controlapi.Profile{}, controlapi.NewError("invalid_request", "routes override must be %q or %q",
			state.OverrideRoutesOn, state.OverrideRoutesOff)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	next := cloneState(s.st)
	configured, err := locationProfile(&next, name)
	if err != nil {
		return controlapi.Profile{}, err
	}
	loc, err := enabledLocation(configured)
	if err != nil {
		return controlapi.Profile{}, err
	}
	if request.Routes == state.OverrideRoutesOn && !configured.AcceptAllRoutes && !configured.AcceptAllDNSRoutes {
		// Location never turns on routes the configuration turned off.
		return controlapi.Profile{}, controlapi.NewError("invalid_request",
			"profile %q does not accept all routes, so routes cannot be forced on", name)
	}
	loc.Override = request.Routes
	return s.commitProfileLocationLocked(next, configured.ID, false)
}

func (s *supervisor) ClearLocationOverride(_ context.Context, name string) (controlapi.Profile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := cloneState(s.st)
	configured, err := locationProfile(&next, name)
	if err != nil {
		return controlapi.Profile{}, err
	}
	loc, err := enabledLocation(configured)
	if err != nil {
		return controlapi.Profile{}, err
	}
	loc.Override = ""
	return s.commitProfileLocationLocked(next, configured.ID, false)
}

// routesInEffect reports whether any accept-all route import is in effect for
// configured after applying location.
func routesInEffect(configured state.Profile) bool {
	return configured.EffectiveAcceptAllRoutes() || configured.EffectiveAcceptAllDNSRoutes()
}

// projectLocationLocked returns the API view of an enabled location.
func (s *supervisor) projectLocationLocked(loc *state.Location) *controlapi.ProfileLocation {
	if loc == nil || !loc.Enabled {
		return nil
	}
	current := loc.Current
	if current == "" {
		current = "unknown"
	}
	return &controlapi.ProfileLocation{
		Supported:        !s.locationUnsupported.Load(),
		Enabled:          true,
		Current:          current,
		Override:         loc.Override,
		HomeNetworks:     append([]string(nil), loc.HomeGateways...),
		NetworkAvailable: len(s.seenGateways) > 0,
		OnHomeNetwork: slices.ContainsFunc(s.seenGateways, func(gw string) bool {
			return slices.Contains(loc.HomeGateways, gw)
		}),
	}
}
