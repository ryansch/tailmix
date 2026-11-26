package profile

import (
	"time"

	"tailscale.com/ipn/ipnstate"
)

// keyExpiryState reports the node key's expiry from st and whether the
// backend needs a login because that key has expired. expiry is nil when the
// key never expires or the status has no self node (for example after a
// logout).
func keyExpiryState(st *ipnstate.Status, now time.Time) (expiry *time.Time, expired bool) {
	if st == nil || st.Self == nil || st.Self.KeyExpiry == nil {
		return nil, false
	}
	t := *st.Self.KeyExpiry
	expiry = &t
	expired = st.BackendState == "NeedsLogin" && !expiry.After(now)
	return expiry, expired
}
