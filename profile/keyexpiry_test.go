package profile

import (
	"testing"
	"time"

	"tailscale.com/ipn/ipnstate"
)

func TestKeyExpiryState(t *testing.T) {
	now := time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	inTwoDays := now.Add(48 * time.Hour)
	hourAgo := now.Add(-time.Hour)
	inAnHour := now.Add(time.Hour)
	tests := []struct {
		name        string
		st          *ipnstate.Status
		wantExpiry  *time.Time
		wantExpired bool
	}{
		{name: "nil status", st: nil},
		{name: "nil self", st: &ipnstate.Status{BackendState: "Running"}},
		{name: "self without expiry", st: &ipnstate.Status{BackendState: "Running", Self: &ipnstate.PeerStatus{}}},
		{name: "running expiry in two days", st: &ipnstate.Status{BackendState: "Running", Self: &ipnstate.PeerStatus{KeyExpiry: &inTwoDays}}, wantExpiry: &inTwoDays},
		{name: "needs login expired an hour ago", st: &ipnstate.Status{BackendState: "NeedsLogin", Self: &ipnstate.PeerStatus{KeyExpiry: &hourAgo}}, wantExpiry: &hourAgo, wantExpired: true},
		{name: "needs login expiring now", st: &ipnstate.Status{BackendState: "NeedsLogin", Self: &ipnstate.PeerStatus{KeyExpiry: &now}}, wantExpiry: &now, wantExpired: true},
		{name: "needs login logged out", st: &ipnstate.Status{BackendState: "NeedsLogin"}},
		{name: "needs login self without expiry", st: &ipnstate.Status{BackendState: "NeedsLogin", Self: &ipnstate.PeerStatus{}}},
		{name: "needs login expiry in future", st: &ipnstate.Status{BackendState: "NeedsLogin", Self: &ipnstate.PeerStatus{KeyExpiry: &inAnHour}}, wantExpiry: &inAnHour},
		{name: "running past expiry", st: &ipnstate.Status{BackendState: "Running", Self: &ipnstate.PeerStatus{KeyExpiry: &hourAgo}}, wantExpiry: &hourAgo},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			expiry, expired := keyExpiryState(tt.st, now)
			if expired != tt.wantExpired {
				t.Fatalf("expired = %v, want %v", expired, tt.wantExpired)
			}
			if (expiry == nil) != (tt.wantExpiry == nil) {
				t.Fatalf("expiry = %v, want %v", expiry, tt.wantExpiry)
			}
			if expiry == nil {
				return
			}
			if !expiry.Equal(*tt.wantExpiry) {
				t.Fatalf("expiry = %v, want %v", *expiry, *tt.wantExpiry)
			}
			if tt.st.Self != nil && expiry == tt.st.Self.KeyExpiry {
				t.Fatal("expiry aliases the status's KeyExpiry; want a copy")
			}
		})
	}
}
