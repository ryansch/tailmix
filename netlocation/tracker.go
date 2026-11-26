// Package netlocation decides whether the host is at one of a profile's home
// networks, identified by default-gateway MAC address.
package netlocation

import (
	"slices"
	"sync"
	"time"
)

// Location values. They match state.LocationHome and state.LocationAway; the
// empty string means unknown.
const (
	locationHome = "home"
	locationAway = "away"
)

// Tracker turns gateway observations into per-profile home/away locations.
// Arriving home takes effect immediately; leaving takes effect only after the
// host has been on a non-home network for the grace period. A Tracker is safe
// for concurrent use.
type Tracker struct {
	grace time.Duration

	mu        sync.Mutex
	awaySince map[string]time.Time // profile ID -> first non-home observation
}

// NewTracker returns a Tracker that waits grace before moving a profile away.
func NewTracker(grace time.Duration) *Tracker {
	return &Tracker{grace: grace, awaySince: make(map[string]time.Time)}
}

// Next returns profileID's next location. current is the persisted location
// ("home", "away" or ""), home the profile's home gateways, seen the gateways
// observed now (empty = no network).
func (t *Tracker) Next(profileID, current string, home, seen []string, now time.Time) string {
	t.mu.Lock()
	defer t.mu.Unlock()

	if len(seen) == 0 {
		// No network: keep the current state and restart the grace period
		// on the next non-home network.
		delete(t.awaySince, profileID)
		return current
	}
	if slices.ContainsFunc(seen, func(gw string) bool { return slices.Contains(home, gw) }) {
		delete(t.awaySince, profileID)
		return locationHome
	}
	if current == locationAway {
		delete(t.awaySince, profileID)
		return locationAway
	}
	start, ok := t.awaySince[profileID]
	if !ok {
		start = now
		t.awaySince[profileID] = start
	}
	if now.Sub(start) >= t.grace {
		delete(t.awaySince, profileID)
		return locationAway
	}
	return current
}

// Forget drops any pending away timer for profileID.
func (t *Tracker) Forget(profileID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.awaySince, profileID)
}

// ClearsOverride reports whether moving from prev to next ends an override:
// a change between two known locations does, a change to or from unknown
// does not.
func ClearsOverride(prev, next string) bool {
	return prev != "" && next != "" && prev != next
}
