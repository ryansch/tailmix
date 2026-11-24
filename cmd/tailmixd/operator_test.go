package main

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/maisem/tailmix/controlapi"
	"github.com/maisem/tailmix/state"
)

func TestOperatorPersistsAndAuthorizes(t *testing.T) {
	store := state.NewJSONStore(filepath.Join(t.TempDir(), "state.json"))
	if err := store.Save(state.State{}); err != nil {
		t.Fatal(err)
	}
	s := newSupervisor(store, state.State{}, nil, daemonConfig{})
	ctx := context.Background()

	if got, err := s.Operator(ctx); err != nil || got.UID != "" {
		t.Fatalf("initial operator = %+v, %v", got, err)
	}
	if got, err := s.SetOperator(ctx, controlapi.SetOperatorRequest{UID: "501"}); err != nil || got.UID != "501" {
		t.Fatalf("set operator = %+v, %v", got, err)
	}
	if got := s.operatorUID(); got != "501" {
		t.Fatalf("operatorUID = %q, want 501", got)
	}
	saved, err := store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if saved.OperatorUID != "501" {
		t.Fatalf("saved operator = %q, want 501", saved.OperatorUID)
	}
	if reloaded := newSupervisor(store, saved, nil, daemonConfig{}); reloaded.operatorUID() != "501" {
		t.Fatalf("reloaded operatorUID = %q, want 501", reloaded.operatorUID())
	}

	if got, err := s.ClearOperator(ctx); err != nil || got.UID != "" {
		t.Fatalf("clear operator = %+v, %v", got, err)
	}
	if got := s.operatorUID(); got != "" {
		t.Fatalf("operatorUID after clear = %q", got)
	}
	saved, err = store.Load()
	if err != nil {
		t.Fatal(err)
	}
	if saved.OperatorUID != "" {
		t.Fatalf("saved operator after clear = %q", saved.OperatorUID)
	}
}

func TestParseOperatorUID(t *testing.T) {
	for _, valid := range []string{"1", "501", "4294967295"} {
		if got, err := parseOperatorUID(valid); err != nil || got != valid {
			t.Errorf("parseOperatorUID(%q) = %q, %v", valid, got, err)
		}
	}
	for _, invalid := range []string{"", "0", "00", "0501", "-1", "+5", "alice", "4294967296", " 501"} {
		if _, err := parseOperatorUID(invalid); err == nil {
			t.Errorf("parseOperatorUID(%q) succeeded, want error", invalid)
		}
	}
}
