package main

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"

	tailmixprofile "github.com/maisem/tailmix/profile"
)

// loginEngine is a lifecycleEngine that can start a sign-in and counts the
// calls.
type loginEngine struct {
	lifecycleEngine
	calls atomic.Int32
	err   error
}

func (e *loginEngine) StartLogin(context.Context) error {
	e.calls.Add(1)
	return e.err
}

func loginTestSupervisor(t *testing.T, status tailmixprofile.Status) (*supervisor, *loginEngine) {
	t.Helper()
	s := newLifecycleTestSupervisor(t, lifecycleTestState())
	engine := &loginEngine{lifecycleEngine: lifecycleEngine{status: status}}
	s.runtimes["p_work"] = &managedProfile{runtime: runtimeProfile{Engine: engine}, status: status, statusFresh: true}
	return s, engine
}

// reconcileAndWait runs a reconcile and waits for any sign-in it started.
func reconcileAndWait(t *testing.T, s *supervisor) {
	t.Helper()
	s.mu.Lock()
	err := s.reconcileLocked()
	s.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	s.loginStarts.Wait()
}

func needsLoginStatus(id string) tailmixprofile.Status {
	return tailmixprofile.Status{ProfileID: id, BackendState: "NeedsLogin"}
}

func TestLoginStartedWhenNeedsLoginWithoutURL(t *testing.T) {
	s, engine := loginTestSupervisor(t, needsLoginStatus("p_work"))

	reconcileAndWait(t, s)

	if got := engine.calls.Load(); got != 1 {
		t.Fatalf("StartLogin calls = %d, want 1", got)
	}
}

func TestLoginStartedOncePerEpisode(t *testing.T) {
	s, engine := loginTestSupervisor(t, needsLoginStatus("p_work"))

	for range 6 {
		reconcileAndWait(t, s)
	}

	if got := engine.calls.Load(); got != 1 {
		t.Fatalf("StartLogin calls after 6 reconciles = %d, want 1", got)
	}
}

func TestLoginStartedAgainAfterURLCleared(t *testing.T) {
	s, engine := loginTestSupervisor(t, needsLoginStatus("p_work"))
	reconcileAndWait(t, s)

	engine.status.AuthURL = "https://login.example/a"
	reconcileAndWait(t, s)
	if got := engine.calls.Load(); got != 1 {
		t.Fatalf("StartLogin calls with a URL = %d, want 1", got)
	}

	engine.status.AuthURL = ""
	reconcileAndWait(t, s)
	if got := engine.calls.Load(); got != 2 {
		t.Fatalf("StartLogin calls after the URL cleared = %d, want 2", got)
	}
}

func TestLoginStartedAgainAfterLeavingNeedsLogin(t *testing.T) {
	s, engine := loginTestSupervisor(t, needsLoginStatus("p_work"))
	reconcileAndWait(t, s)

	engine.status.BackendState = "Running"
	reconcileAndWait(t, s)
	engine.status.BackendState = "NeedsLogin"
	reconcileAndWait(t, s)

	if got := engine.calls.Load(); got != 2 {
		t.Fatalf("StartLogin calls = %d, want 2", got)
	}
}

func TestLoginNotStartedWhenRunning(t *testing.T) {
	s, engine := loginTestSupervisor(t, tailmixprofile.Status{ProfileID: "p_work", BackendState: "Running"})

	reconcileAndWait(t, s)

	if got := engine.calls.Load(); got != 0 {
		t.Fatalf("StartLogin calls = %d, want 0", got)
	}
}

func TestLoginNotStartedWhenURLPresent(t *testing.T) {
	status := needsLoginStatus("p_work")
	status.AuthURL = "https://login.example/a"
	s, engine := loginTestSupervisor(t, status)

	reconcileAndWait(t, s)

	if got := engine.calls.Load(); got != 0 {
		t.Fatalf("StartLogin calls = %d, want 0", got)
	}
}

func TestLoginSkippedForEngineWithoutLoginStarter(t *testing.T) {
	s := newLifecycleTestSupervisor(t, lifecycleTestState())
	status := needsLoginStatus("p_work")
	s.runtimes["p_work"] = &managedProfile{runtime: runtimeProfile{Engine: &lifecycleEngine{status: status}}, status: status}

	reconcileAndWait(t, s)

	if s.runtimes["p_work"].loginStarted {
		t.Fatal("loginStarted = true for an engine that cannot start a sign-in")
	}
}

func TestLoginNotStartedForDisabledOrRemovedProfile(t *testing.T) {
	s := newLifecycleTestSupervisor(t, lifecycleTestState())
	home := &loginEngine{lifecycleEngine: lifecycleEngine{status: needsLoginStatus("p_home")}}
	old := &loginEngine{lifecycleEngine: lifecycleEngine{status: needsLoginStatus("p_old")}}
	s.runtimes["p_home"] = &managedProfile{runtime: runtimeProfile{Engine: home}, status: home.status}
	s.runtimes["p_old"] = &managedProfile{runtime: runtimeProfile{Engine: old}, status: old.status}

	reconcileAndWait(t, s)

	if home.calls.Load() != 0 || old.calls.Load() != 0 {
		t.Fatalf("StartLogin calls: disabled=%d removed=%d, want 0", home.calls.Load(), old.calls.Load())
	}
}

func TestLoginNotStartedForProfileWithoutRuntime(t *testing.T) {
	s := newLifecycleTestSupervisor(t, lifecycleTestState())

	s.mu.Lock()
	s.startPendingLoginsLocked([]tailmixprofile.Status{needsLoginStatus("p_work")})
	s.mu.Unlock()
	s.loginStarts.Wait()
}

func TestLoginStartErrorReported(t *testing.T) {
	s, engine := loginTestSupervisor(t, needsLoginStatus("p_work"))
	engine.err = errors.New("control unreachable")

	s.mu.Lock()
	s.startPendingLoginsLocked([]tailmixprofile.Status{needsLoginStatus("p_work")})
	s.mu.Unlock()
	s.loginStarts.Wait()

	s.mu.Lock()
	defer s.mu.Unlock()
	if got := s.lastErrors["p_work"]; !strings.Contains(got, "start sign-in") || !strings.Contains(got, "control unreachable") {
		t.Fatalf("lastErrors[p_work] = %q, want a start sign-in error", got)
	}
	if !s.runtimes["p_work"].loginStarted {
		t.Fatal("loginStarted cleared after a failed start, want it kept for the episode")
	}
}

func TestLoginStartErrorIgnoredAfterProfileStopped(t *testing.T) {
	s, engine := loginTestSupervisor(t, needsLoginStatus("p_work"))
	engine.err = errors.New("control unreachable")
	release := make(chan struct{})
	blocking := &blockingLoginEngine{loginEngine: engine, release: release}
	s.runtimes["p_work"].runtime.Engine = blocking

	s.mu.Lock()
	s.startPendingLoginsLocked([]tailmixprofile.Status{needsLoginStatus("p_work")})
	delete(s.runtimes, "p_work")
	s.mu.Unlock()
	close(release)
	s.loginStarts.Wait()

	s.mu.Lock()
	defer s.mu.Unlock()
	if got, ok := s.lastErrors["p_work"]; ok {
		t.Fatalf("lastErrors[p_work] = %q, want none for a stopped profile", got)
	}
}

// blockingLoginEngine holds StartLogin until release is closed.
type blockingLoginEngine struct {
	*loginEngine
	release chan struct{}
}

func (e *blockingLoginEngine) StartLogin(ctx context.Context) error {
	<-e.release
	return e.loginEngine.StartLogin(ctx)
}
