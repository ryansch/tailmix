package main

import (
	"fmt"

	tailmixprofile "github.com/maisem/tailmix/profile"
)

// startPendingLoginsLocked starts an interactive sign-in for each running
// profile that needs one and has no sign-in link, so a link appears after a
// key expires while the profile runs. It starts at most one per episode: the
// episode ends when the profile reports a link or leaves NeedsLogin. Each
// start runs in its own goroutine so it never holds s.mu.
func (s *supervisor) startPendingLoginsLocked(statuses []tailmixprofile.Status) {
	for _, status := range statuses {
		managed := s.runtimes[status.ProfileID]
		if managed == nil || !managed.statusFresh {
			continue
		}
		if status.BackendState != "NeedsLogin" || status.AuthURL != "" {
			managed.loginStarted = false
			continue
		}
		if managed.loginStarted {
			continue
		}
		starter, ok := managed.runtime.Engine.(tailmixprofile.LoginStarter)
		if !ok {
			continue
		}
		managed.loginStarted = true
		ctx := s.ctx
		id := status.ProfileID
		name := s.nameForIDLocked(id)
		s.loginStarts.Add(1)
		go func() {
			defer s.loginStarts.Done()
			err := starter.StartLogin(ctx)
			if err == nil || ctx.Err() != nil {
				return
			}
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.runtimes[id] != managed {
				return
			}
			s.lastErrors[id] = fmt.Sprintf("start sign-in: %v", err)
			fmt.Fprintf(s.cfg.Stderr, "profile %s start sign-in: %v\n", name, err)
		}()
	}
}
