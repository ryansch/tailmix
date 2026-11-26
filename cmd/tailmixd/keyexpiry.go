package main

import (
	"fmt"
	"time"

	tailmixprofile "github.com/maisem/tailmix/profile"
	"github.com/maisem/tailmix/state"
)

// recordKeyExpiriesLocked saves each running Tailscale profile's reported
// node key expiry in the daemon state, so a key that expires while tailmixd
// is not running still reads as expired on the next start. It saves only
// when a value changes. A profile running without a key expiry (expiry
// disabled) clears the saved value, and so does one that needs a login with
// no key expiry before the saved expiry has passed: that is a logout, not an
// expired key.
func (s *supervisor) recordKeyExpiriesLocked() {
	type change struct {
		index int
		old   *time.Time
	}
	var changes []change
	now := s.now()
	for i := range s.st.Profiles {
		configured := &s.st.Profiles[i]
		if configured.Kind == state.ProfileKindWireGuard {
			continue
		}
		managed := s.runtimes[configured.ID]
		if managed == nil || !managed.statusFresh {
			continue
		}
		status := managed.status
		var next *time.Time
		switch {
		case status.KeyExpiry != nil:
			if configured.LastKeyExpiry != nil && configured.LastKeyExpiry.Equal(*status.KeyExpiry) {
				continue
			}
			expiry := *status.KeyExpiry
			next = &expiry
		case status.BackendState == "Running" && configured.LastKeyExpiry != nil:
			next = nil
		case status.BackendState == "NeedsLogin" && configured.LastKeyExpiry != nil && configured.LastKeyExpiry.After(now):
			next = nil
		default:
			continue
		}
		changes = append(changes, change{index: i, old: configured.LastKeyExpiry})
		configured.LastKeyExpiry = next
	}
	if len(changes) == 0 {
		return
	}
	if err := s.store.Save(s.st); err != nil {
		for _, c := range changes {
			s.st.Profiles[c.index].LastKeyExpiry = c.old
		}
		fmt.Fprintf(s.cfg.Stderr, "save key expiry: %v\n", err)
	}
}

// projectKeyExpiry returns the key expiry to report for a profile and whether
// it needs a login because that key expired. The saved expiry stands in when
// the engine has none, such as after a restart with an expired key. It counts
// only while the profile still has a node key: a logout removes the key, so a
// logged-out profile never reads as expired.
func projectKeyExpiry(status tailmixprofile.Status, saved *time.Time, now time.Time) (*time.Time, bool) {
	var expiry *time.Time
	switch {
	case status.KeyExpiry != nil:
		t := *status.KeyExpiry
		expiry = &t
	case saved != nil:
		t := *saved
		expiry = &t
	}
	expired := status.KeyExpired ||
		(status.BackendState == "NeedsLogin" && status.HaveNodeKey && saved != nil && !saved.After(now))
	return expiry, expired
}
