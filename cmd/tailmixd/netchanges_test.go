package main

import "testing"

func TestNetmonChangesStartsAndStops(t *testing.T) {
	stop, err := netmonChanges(func() {})
	if err != nil {
		t.Fatalf("netmonChanges: %v", err)
	}
	stop()
}
