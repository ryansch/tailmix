package main

import (
	"os"
	"testing"
	"time"

	tailmixprofile "github.com/maisem/tailmix/profile"
	"github.com/maisem/tailmix/state"
)

func keyExpiryTestSupervisor(t *testing.T, saved *time.Time, status tailmixprofile.Status) (*supervisor, *lifecycleEngine) {
	t.Helper()
	st := lifecycleTestState()
	for i := range st.Profiles {
		if st.Profiles[i].ID == "p_work" {
			st.Profiles[i].LastKeyExpiry = saved
		}
	}
	s := newLifecycleTestSupervisor(t, st)
	engine := &lifecycleEngine{status: status}
	s.runtimes["p_work"] = &managedProfile{runtime: runtimeProfile{Engine: engine}, status: status}
	return s, engine
}

func workProfile(t *testing.T, st state.State) state.Profile {
	t.Helper()
	for _, configured := range st.Profiles {
		if configured.ID == "p_work" {
			return configured
		}
	}
	t.Fatal("p_work not found")
	return state.Profile{}
}

func TestProjectSavedPastKeyExpiryReadsExpired(t *testing.T) {
	saved := time.Now().Add(-time.Hour).UTC().Round(time.Second)
	s, _ := keyExpiryTestSupervisor(t, &saved, tailmixprofile.Status{ProfileID: "p_work", BackendState: "NeedsLogin", HaveNodeKey: true})

	got := s.projectProfileLocked(workProfile(t, s.st))
	if !got.KeyExpired {
		t.Fatal("KeyExpired = false, want true for NeedsLogin with a saved past expiry")
	}
	if got.KeyExpiry == nil || !got.KeyExpiry.Equal(saved) {
		t.Fatalf("KeyExpiry = %v, want saved %v", got.KeyExpiry, saved)
	}
}

func TestProjectSavedFutureKeyExpiryNotExpired(t *testing.T) {
	saved := time.Now().Add(48 * time.Hour).UTC().Round(time.Second)
	s, _ := keyExpiryTestSupervisor(t, &saved, tailmixprofile.Status{ProfileID: "p_work", BackendState: "NeedsLogin", HaveNodeKey: true})

	if got := s.projectProfileLocked(workProfile(t, s.st)); got.KeyExpired {
		t.Fatal("KeyExpired = true, want false for a saved future expiry")
	}
}

func TestKeyExpiryPersistedWhenEngineReportsNewExpiry(t *testing.T) {
	old := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	fresh := time.Date(2027, 5, 1, 0, 0, 0, 0, time.UTC)
	s, engine := keyExpiryTestSupervisor(t, &old, tailmixprofile.Status{ProfileID: "p_work", BackendState: "Running"})
	engine.status.KeyExpiry = &fresh

	_ = s.statusesLocked()

	if got := workProfile(t, s.st).LastKeyExpiry; got == nil || !got.Equal(fresh) || got == engine.status.KeyExpiry {
		t.Fatalf("in-memory LastKeyExpiry = %v, want an unaliased copy of %v", got, fresh)
	}
	loaded, err := s.store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if got := workProfile(t, loaded).LastKeyExpiry; got == nil || !got.Equal(fresh) {
		t.Fatalf("persisted LastKeyExpiry = %v, want %v", got, fresh)
	}
}

func TestKeyExpiryClearedWhenRunningWithoutExpiry(t *testing.T) {
	old := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	s, _ := keyExpiryTestSupervisor(t, &old, tailmixprofile.Status{ProfileID: "p_work", BackendState: "Running"})

	_ = s.statusesLocked()

	if got := workProfile(t, s.st).LastKeyExpiry; got != nil {
		t.Fatalf("in-memory LastKeyExpiry = %v, want nil", got)
	}
	loaded, err := s.store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if got := workProfile(t, loaded).LastKeyExpiry; got != nil {
		t.Fatalf("persisted LastKeyExpiry = %v, want nil", got)
	}
}

func TestKeyExpiryKeptWhenNeedsLoginWithoutExpiry(t *testing.T) {
	old := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	s, _ := keyExpiryTestSupervisor(t, &old, tailmixprofile.Status{ProfileID: "p_work", BackendState: "NeedsLogin", HaveNodeKey: true})
	s.clock = func() time.Time { return old.Add(time.Hour) }

	_ = s.statusesLocked()

	if got := workProfile(t, s.st).LastKeyExpiry; got == nil || !got.Equal(old) {
		t.Fatalf("LastKeyExpiry = %v, want %v kept", got, old)
	}
}

func TestKeyExpiryUnchangedStatusDoesNotSave(t *testing.T) {
	expiry := time.Date(2027, 5, 1, 0, 0, 0, 0, time.UTC)
	same := expiry
	s, _ := keyExpiryTestSupervisor(t, &expiry, tailmixprofile.Status{ProfileID: "p_work", BackendState: "Running", KeyExpiry: &same})
	if err := os.Remove(s.store.Path()); err != nil {
		t.Fatal(err)
	}

	_ = s.statusesLocked()

	if _, err := os.Stat(s.store.Path()); !os.IsNotExist(err) {
		t.Fatalf("state file stat err = %v, want it not rewritten", err)
	}
}

func TestProjectUsesSupervisorClock(t *testing.T) {
	saved := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	s, _ := keyExpiryTestSupervisor(t, &saved, tailmixprofile.Status{ProfileID: "p_work", BackendState: "NeedsLogin", HaveNodeKey: true})

	s.clock = func() time.Time { return saved.Add(-time.Hour) }
	if got := s.projectProfileLocked(workProfile(t, s.st)); got.KeyExpired {
		t.Fatal("KeyExpired = true before the saved expiry on the supervisor clock")
	}
	s.clock = func() time.Time { return saved.Add(time.Hour) }
	if got := s.projectProfileLocked(workProfile(t, s.st)); !got.KeyExpired {
		t.Fatal("KeyExpired = false after the saved expiry on the supervisor clock")
	}
}

func TestKeyExpiryClearedOnLogoutBeforeExpiry(t *testing.T) {
	now := time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	saved := now.Add(48 * time.Hour)
	// A logout leaves NeedsLogin with no key expiry; HaveNodeKey stays true
	// here so the cleared saved value alone keeps this from reading expired.
	s, _ := keyExpiryTestSupervisor(t, &saved, tailmixprofile.Status{ProfileID: "p_work", BackendState: "NeedsLogin", HaveNodeKey: true})
	s.clock = func() time.Time { return now }

	_ = s.statusesLocked()

	if got := workProfile(t, s.st).LastKeyExpiry; got != nil {
		t.Fatalf("in-memory LastKeyExpiry = %v, want nil after a logout", got)
	}
	loaded, err := s.store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if got := workProfile(t, loaded).LastKeyExpiry; got != nil {
		t.Fatalf("persisted LastKeyExpiry = %v, want nil after a logout", got)
	}
	s.clock = func() time.Time { return saved.Add(time.Hour) }
	if got := s.projectProfileLocked(workProfile(t, s.st)); got.KeyExpired || got.KeyExpiry != nil {
		t.Fatalf("after the old expiry: KeyExpired = %v, KeyExpiry = %v; want false, nil", got.KeyExpired, got.KeyExpiry)
	}
}

func TestProjectSavedPastKeyExpiryWithoutNodeKeyNotExpired(t *testing.T) {
	saved := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	s, _ := keyExpiryTestSupervisor(t, &saved, tailmixprofile.Status{ProfileID: "p_work", BackendState: "NeedsLogin"})
	s.clock = func() time.Time { return saved.Add(time.Hour) }

	if got := s.projectProfileLocked(workProfile(t, s.st)); got.KeyExpired {
		t.Fatal("KeyExpired = true, want false for NeedsLogin without a node key (logged out)")
	}
}
