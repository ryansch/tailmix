package main

import (
	"tailscale.com/net/netmon"
	"tailscale.com/types/logger"
	"tailscale.com/util/eventbus"
)

// netmonChanges calls notify whenever netmon sees the host's network change,
// until the returned stop function is called. netmon's own logging is
// discarded: it names gateways and addresses.
func netmonChanges(notify func()) (func(), error) {
	bus := eventbus.New()
	mon, err := netmon.New(bus, logger.Discard)
	if err != nil {
		bus.Close()
		return nil, err
	}
	unregister := mon.RegisterChangeCallback(func(*netmon.ChangeDelta) { notify() })
	mon.Start()
	return func() {
		unregister()
		mon.Close()
		bus.Close()
	}, nil
}
