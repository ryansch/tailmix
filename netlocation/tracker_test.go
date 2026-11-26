package netlocation

import (
	"testing"
	"time"
)

const (
	homeGW    = "aa:bb:cc:dd:ee:01"
	officeGW  = "aa:bb:cc:dd:ee:02"
	hotspotGW = "aa:bb:cc:dd:ee:03"
	grace     = 60 * time.Second
)

var t0 = time.Date(2026, 11, 25, 12, 0, 0, 0, time.UTC)

type step struct {
	at   time.Duration // offset from t0
	seen []string
	want string
}

// run feeds steps for profile "p" with homes as the home list, persisting
// each result as the next call's current location.
func run(t *testing.T, tr *Tracker, current string, homes []string, steps []step) {
	t.Helper()
	for i, s := range steps {
		got := tr.Next("p", current, homes, s.seen, t0.Add(s.at))
		if got != s.want {
			t.Fatalf("step %d (t0+%v, seen %v, current %q): got %q, want %q", i, s.at, s.seen, current, got, s.want)
		}
		current = got
	}
}

func TestTracker(t *testing.T) {
	homes := []string{homeGW}

	t.Run("home gateway switches immediately", func(t *testing.T) {
		for _, from := range []string{"", "away"} {
			tr := NewTracker(grace)
			if got := tr.Next("p", from, homes, []string{homeGW}, t0); got != "home" {
				t.Errorf("from %q: got %q, want %q", from, got, "home")
			}
		}
	})

	t.Run("any interface on home wins", func(t *testing.T) {
		tr := NewTracker(grace)
		if got := tr.Next("p", "away", homes, []string{hotspotGW, homeGW}, t0); got != "home" {
			t.Errorf("got %q, want %q", got, "home")
		}
	})

	t.Run("away waits for grace", func(t *testing.T) {
		run(t, NewTracker(grace), "home", homes, []step{
			{0, []string{officeGW}, "home"},
			{59 * time.Second, []string{officeGW}, "home"},
			{60 * time.Second, []string{officeGW}, "away"},
		})
	})

	t.Run("unknown start waits for grace", func(t *testing.T) {
		run(t, NewTracker(grace), "", homes, []step{
			{0, []string{officeGW}, ""},
			{60 * time.Second, []string{officeGW}, "away"},
		})
	})

	t.Run("outage keeps state", func(t *testing.T) {
		var steps []step
		for at := time.Duration(0); at <= 10*time.Minute; at += 5 * time.Second {
			steps = append(steps, step{at, nil, "home"})
		}
		run(t, NewTracker(grace), "home", homes, steps)
	})

	t.Run("outage restarts grace", func(t *testing.T) {
		run(t, NewTracker(grace), "home", homes, []step{
			{0, []string{officeGW}, "home"},
			{30 * time.Second, nil, "home"},
			{40 * time.Second, []string{officeGW}, "home"},
			{99 * time.Second, []string{officeGW}, "home"},
			{100 * time.Second, []string{officeGW}, "away"},
		})
	})

	t.Run("home visit restarts grace", func(t *testing.T) {
		run(t, NewTracker(grace), "home", homes, []step{
			{0, []string{officeGW}, "home"},
			{30 * time.Second, []string{homeGW}, "home"},
			{40 * time.Second, []string{officeGW}, "home"},
			{99 * time.Second, []string{officeGW}, "home"},
			{100 * time.Second, []string{officeGW}, "away"},
		})
	})

	t.Run("profiles are independent", func(t *testing.T) {
		tr := NewTracker(grace)
		aHomes := []string{homeGW}
		bHomes := []string{officeGW}
		seen := []string{officeGW}
		if got := tr.Next("a", "home", aHomes, seen, t0); got != "home" {
			t.Errorf("a at t0: got %q, want %q", got, "home")
		}
		if got := tr.Next("b", "away", bHomes, seen, t0); got != "home" {
			t.Errorf("b at t0: got %q, want %q", got, "home")
		}
		// b's arrival home must not clear a's pending timer.
		if got := tr.Next("a", "home", aHomes, seen, t0.Add(grace)); got != "away" {
			t.Errorf("a at t0+grace: got %q, want %q", got, "away")
		}
		if got := tr.Next("b", "home", bHomes, seen, t0.Add(grace)); got != "home" {
			t.Errorf("b at t0+grace: got %q, want %q", got, "home")
		}
	})

	t.Run("forget drops pending timer", func(t *testing.T) {
		tr := NewTracker(grace)
		tr.Next("p", "home", homes, []string{officeGW}, t0)
		tr.Forget("p")
		if got := tr.Next("p", "home", homes, []string{officeGW}, t0.Add(grace)); got != "home" {
			t.Errorf("after Forget: got %q, want %q", got, "home")
		}
	})
}

func TestClearsOverride(t *testing.T) {
	for _, tc := range []struct {
		prev, next string
		want       bool
	}{
		{"home", "away", true},
		{"away", "home", true},
		{"", "home", false},
		{"home", "", false},
		{"home", "home", false},
	} {
		if got := ClearsOverride(tc.prev, tc.next); got != tc.want {
			t.Errorf("ClearsOverride(%q, %q) = %v, want %v", tc.prev, tc.next, got, tc.want)
		}
	}
}
