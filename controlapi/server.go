package controlapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"

	tailmixversion "github.com/maisem/tailmix/version"
	"github.com/maisem/tailmix/wireguardcfg"
)

type Backend interface {
	Status(context.Context) (Status, error)
	SetDaemonUp(context.Context, bool) (DaemonState, error)
	ListProfiles(context.Context, bool) (Profiles, error)
	GetProfile(context.Context, string) (Profile, error)
	AddProfile(context.Context, AddProfileRequest) (Profile, error)
	PatchProfile(context.Context, string, PatchProfileRequest) (Profile, error)
	SetProfileEnabled(context.Context, string, bool) (Profile, error)
	RestartProfile(context.Context, string) (Profile, error)
	RemoveProfile(context.Context, string, bool) (Profile, error)
	ApplyWireGuard(context.Context, wireguardcfg.Config, wireguardcfg.Secrets) (WireGuardProfile, error)
	WireGuardProfile(context.Context, string) (WireGuardProfile, error)
	SetWireGuardShieldsUp(context.Context, string, bool) (WireGuardProfile, error)

	IPRoutes(context.Context, bool) (IPRoutes, error)
	PatchIPRoutes(context.Context, PatchIPRoutesRequest) (IPRoutes, error)
	ReplaceIPRoutes(context.Context, ReplaceIPRoutesRequest) (IPRoutes, error)
	ClearIPRoutes(context.Context) (IPRoutes, error)

	ExitNodes(context.Context) (ExitNodes, error)
	SetExitNode(context.Context, SetExitNodeRequest) (ExitNodes, error)
	ClearExitNode(context.Context) (ExitNodes, error)

	DNSRoutes(context.Context, bool) (DNSRoutes, error)
	PatchDNSRoutes(context.Context, PatchDNSRoutesRequest) (DNSRoutes, error)
	ReplaceDNSRoutes(context.Context, ReplaceDNSRoutesRequest) (DNSRoutes, error)
	ClearDNSRoutes(context.Context) (DNSRoutes, error)

	SearchDomains(context.Context) (SearchDomains, error)
	PatchSearchDomains(context.Context, PatchSearchDomainsRequest) (SearchDomains, error)
	ReplaceSearchDomains(context.Context, ReplaceSearchDomainsRequest) (SearchDomains, error)
	ClearSearchDomains(context.Context) (SearchDomains, error)
}

// UpdateBackend is implemented by daemons that support self-updates. It is
// separate from Backend so the control API remains usable by restricted and
// test backends that do not manage installed binaries.
type UpdateBackend interface {
	UpdateStatus(context.Context) (UpdateStatus, error)
	SetUpdatesEnabled(context.Context, bool) (UpdateStatus, error)
	CheckForUpdate(context.Context) (UpdateStatus, error)
	ApplyUpdate(context.Context) (UpdateStatus, error)
}

// OperatorBackend is implemented by daemons that let a configured non-root
// user perform the operations listed by OperatorRoutes.
type OperatorBackend interface {
	Operator(context.Context) (Operator, error)
	SetOperator(context.Context, SetOperatorRequest) (Operator, error)
	ClearOperator(context.Context) (Operator, error)
}

// LocationBackend is implemented by daemons that turn a profile's accept-all
// routes off while the host is on one of that profile's home networks.
type LocationBackend interface {
	SetProfileLocation(ctx context.Context, name string, request SetLocationRequest) (Profile, error)
	MarkCurrentNetworkHome(ctx context.Context, name string) (Profile, error)
	// ForgetHomeNetwork removes gateway from the profile's home networks;
	// gateway "current" removes every gateway seen now.
	ForgetHomeNetwork(ctx context.Context, name, gateway string) (Profile, error)
	SetLocationOverride(ctx context.Context, name string, request SetLocationOverrideRequest) (Profile, error)
	ClearLocationOverride(ctx context.Context, name string) (Profile, error)
}

// OperatorRoutes returns a handler whose registered patterns are exactly the
// mutations a configured operator may perform: connecting or disconnecting a
// profile, selecting or clearing the exit node, marking or forgetting the
// current network as a profile's home network, and setting or clearing a
// profile's location override. Turning location on or off and forgetting a
// named home network stay root-only. Use its Handler method to test whether a
// request matches.
func OperatorRoutes() *http.ServeMux {
	mux := http.NewServeMux()
	allowed := http.NotFoundHandler()
	mux.Handle("POST /v1/profiles/by-name/{name}/enable", allowed)
	mux.Handle("POST /v1/profiles/by-name/{name}/disable", allowed)
	mux.Handle("PUT /v1/exit-node", allowed)
	mux.Handle("DELETE /v1/exit-node", allowed)
	mux.Handle("POST /v1/profiles/by-name/{name}/location/home-networks/current", allowed)
	mux.Handle("DELETE /v1/profiles/by-name/{name}/location/home-networks/current", allowed)
	mux.Handle("PUT /v1/profiles/by-name/{name}/location/override", allowed)
	mux.Handle("DELETE /v1/profiles/by-name/{name}/location/override", allowed)
	return mux
}

func Handler(backend Backend) http.Handler {
	mux := http.NewServeMux()
	updates, hasUpdates := backend.(UpdateBackend)
	updateUnavailable := func(w http.ResponseWriter) {
		writeResult(w, nil, NewError("unsupported", "this daemon does not support automatic updates"))
	}
	operators, hasOperators := backend.(OperatorBackend)
	operatorUnavailable := func(w http.ResponseWriter) {
		writeResult(w, nil, NewError("unsupported", "this daemon does not support an operator"))
	}
	mux.HandleFunc("GET /v1/operator", func(w http.ResponseWriter, r *http.Request) {
		if !hasOperators {
			operatorUnavailable(w)
			return
		}
		result, err := operators.Operator(r.Context())
		writeResult(w, result, err)
	})
	mux.HandleFunc("PUT /v1/operator", func(w http.ResponseWriter, r *http.Request) {
		if !hasOperators {
			operatorUnavailable(w)
			return
		}
		var request SetOperatorRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := operators.SetOperator(r.Context(), request)
		writeResult(w, result, err)
	})
	mux.HandleFunc("DELETE /v1/operator", func(w http.ResponseWriter, r *http.Request) {
		if !hasOperators {
			operatorUnavailable(w)
			return
		}
		result, err := operators.ClearOperator(r.Context())
		writeResult(w, result, err)
	})
	mux.HandleFunc("GET /v1/version", func(w http.ResponseWriter, _ *http.Request) {
		writeResult(w, tailmixversion.GetMeta(), nil)
	})
	mux.HandleFunc("GET /v1/status", func(w http.ResponseWriter, r *http.Request) {
		result, err := backend.Status(r.Context())
		writeResult(w, result, err)
	})
	for _, action := range []string{"up", "down"} {
		action := action
		mux.HandleFunc("POST /v1/"+action, func(w http.ResponseWriter, r *http.Request) {
			result, err := backend.SetDaemonUp(r.Context(), action == "up")
			writeResult(w, result, err)
		})
	}
	mux.HandleFunc("GET /v1/update", func(w http.ResponseWriter, r *http.Request) {
		if !hasUpdates {
			updateUnavailable(w)
			return
		}
		result, err := updates.UpdateStatus(r.Context())
		writeResult(w, result, err)
	})
	for _, action := range []string{"enable", "disable", "check", "apply"} {
		action := action
		mux.HandleFunc("POST /v1/update/"+action, func(w http.ResponseWriter, r *http.Request) {
			if !hasUpdates {
				updateUnavailable(w)
				return
			}
			var result UpdateStatus
			var err error
			switch action {
			case "enable":
				result, err = updates.SetUpdatesEnabled(r.Context(), true)
			case "disable":
				result, err = updates.SetUpdatesEnabled(r.Context(), false)
			case "check":
				result, err = updates.CheckForUpdate(r.Context())
			case "apply":
				result, err = updates.ApplyUpdate(r.Context())
			}
			writeResult(w, result, err)
		})
	}
	mux.HandleFunc("GET /v1/profiles", func(w http.ResponseWriter, r *http.Request) {
		all, _ := strconv.ParseBool(r.URL.Query().Get("all"))
		result, err := backend.ListProfiles(r.Context(), all)
		writeResult(w, result, err)
	})
	mux.HandleFunc("POST /v1/profiles", func(w http.ResponseWriter, r *http.Request) {
		var request AddProfileRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := backend.AddProfile(r.Context(), request)
		writeResult(w, result, err)
	})
	mux.HandleFunc("GET /v1/profiles/by-name/{name}", func(w http.ResponseWriter, r *http.Request) {
		name, err := url.PathUnescape(r.PathValue("name"))
		if err != nil {
			writeResult(w, nil, NewError("invalid_request", "invalid escaped profile name"))
			return
		}
		result, backendErr := backend.GetProfile(r.Context(), name)
		writeResult(w, result, backendErr)
	})
	mux.HandleFunc("PATCH /v1/profiles/by-name/{name}", func(w http.ResponseWriter, r *http.Request) {
		name, err := url.PathUnescape(r.PathValue("name"))
		if err != nil {
			writeResult(w, nil, NewError("invalid_request", "invalid escaped profile name"))
			return
		}
		var request PatchProfileRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, backendErr := backend.PatchProfile(r.Context(), name, request)
		writeResult(w, result, backendErr)
	})
	for _, action := range []string{"enable", "disable", "restart"} {
		mux.HandleFunc("POST /v1/profiles/by-name/{name}/"+action, profileActionHandler(backend, action))
	}
	mux.HandleFunc("DELETE /v1/profiles/by-name/{name}", func(w http.ResponseWriter, r *http.Request) {
		name, err := url.PathUnescape(r.PathValue("name"))
		if err != nil {
			writeResult(w, nil, NewError("invalid_request", "invalid escaped profile name"))
			return
		}
		purge, _ := strconv.ParseBool(r.URL.Query().Get("purge"))
		result, backendErr := backend.RemoveProfile(r.Context(), name, purge)
		writeResult(w, result, backendErr)
	})
	locations, hasLocations := backend.(LocationBackend)
	handleLocation := func(pattern string, serve func(http.ResponseWriter, *http.Request, string)) {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			if !hasLocations {
				writeResult(w, nil, NewError("unsupported", "this daemon does not support profile location"))
				return
			}
			name, err := url.PathUnescape(r.PathValue("name"))
			if err != nil {
				writeResult(w, nil, NewError("invalid_request", "invalid escaped profile name"))
				return
			}
			serve(w, r, name)
		})
	}
	handleLocation("PUT /v1/profiles/by-name/{name}/location", func(w http.ResponseWriter, r *http.Request, name string) {
		var request SetLocationRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := locations.SetProfileLocation(r.Context(), name, request)
		writeResult(w, result, err)
	})
	handleLocation("POST /v1/profiles/by-name/{name}/location/home-networks/current", func(w http.ResponseWriter, r *http.Request, name string) {
		result, err := locations.MarkCurrentNetworkHome(r.Context(), name)
		writeResult(w, result, err)
	})
	// The literal "current" pattern is more specific than {gateway}, so it
	// wins; OperatorRoutes lists only the literal one.
	handleLocation("DELETE /v1/profiles/by-name/{name}/location/home-networks/current", func(w http.ResponseWriter, r *http.Request, name string) {
		result, err := locations.ForgetHomeNetwork(r.Context(), name, "current")
		writeResult(w, result, err)
	})
	handleLocation("DELETE /v1/profiles/by-name/{name}/location/home-networks/{gateway}", func(w http.ResponseWriter, r *http.Request, name string) {
		result, err := locations.ForgetHomeNetwork(r.Context(), name, r.PathValue("gateway"))
		writeResult(w, result, err)
	})
	handleLocation("PUT /v1/profiles/by-name/{name}/location/override", func(w http.ResponseWriter, r *http.Request, name string) {
		var request SetLocationOverrideRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := locations.SetLocationOverride(r.Context(), name, request)
		writeResult(w, result, err)
	})
	handleLocation("DELETE /v1/profiles/by-name/{name}/location/override", func(w http.ResponseWriter, r *http.Request, name string) {
		result, err := locations.ClearLocationOverride(r.Context(), name)
		writeResult(w, result, err)
	})
	mux.HandleFunc("POST /v1/wireguard", func(w http.ResponseWriter, r *http.Request) {
		var request ApplyWireGuardRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := backend.ApplyWireGuard(r.Context(), request.Config, request.Secrets)
		writeResult(w, result, err)
	})
	mux.HandleFunc("GET /v1/wireguard/by-name/{name}", func(w http.ResponseWriter, r *http.Request) {
		name, err := url.PathUnescape(r.PathValue("name"))
		if err != nil {
			writeResult(w, nil, NewError("invalid_request", "invalid escaped profile name"))
			return
		}
		result, backendErr := backend.WireGuardProfile(r.Context(), name)
		writeResult(w, result, backendErr)
	})
	mux.HandleFunc("POST /v1/wireguard/by-name/{name}/shields-up", func(w http.ResponseWriter, r *http.Request) {
		name, err := url.PathUnescape(r.PathValue("name"))
		if err != nil {
			writeResult(w, nil, NewError("invalid_request", "invalid escaped profile name"))
			return
		}
		var request WireGuardShieldsUpRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, backendErr := backend.SetWireGuardShieldsUp(r.Context(), name, request.Enabled)
		writeResult(w, result, backendErr)
	})

	mux.HandleFunc("GET /v1/routes", func(w http.ResponseWriter, r *http.Request) {
		result, err := backend.IPRoutes(r.Context(), false)
		writeResult(w, result, err)
	})
	mux.HandleFunc("GET /v1/routes/available", func(w http.ResponseWriter, r *http.Request) {
		result, err := backend.IPRoutes(r.Context(), true)
		writeResult(w, result, err)
	})
	mux.HandleFunc("PUT /v1/routes", func(w http.ResponseWriter, r *http.Request) {
		var request ReplaceIPRoutesRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := backend.ReplaceIPRoutes(r.Context(), request)
		writeResult(w, result, err)
	})
	mux.HandleFunc("PATCH /v1/routes", func(w http.ResponseWriter, r *http.Request) {
		var request PatchIPRoutesRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := backend.PatchIPRoutes(r.Context(), request)
		writeResult(w, result, err)
	})
	mux.HandleFunc("DELETE /v1/routes", func(w http.ResponseWriter, r *http.Request) {
		result, err := backend.ClearIPRoutes(r.Context())
		writeResult(w, result, err)
	})

	mux.HandleFunc("GET /v1/exit-node", func(w http.ResponseWriter, r *http.Request) {
		result, err := backend.ExitNodes(r.Context())
		writeResult(w, result, err)
	})
	mux.HandleFunc("PUT /v1/exit-node", func(w http.ResponseWriter, r *http.Request) {
		var request SetExitNodeRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := backend.SetExitNode(r.Context(), request)
		writeResult(w, result, err)
	})
	mux.HandleFunc("DELETE /v1/exit-node", func(w http.ResponseWriter, r *http.Request) {
		result, err := backend.ClearExitNode(r.Context())
		writeResult(w, result, err)
	})

	mux.HandleFunc("GET /v1/dns/routes", func(w http.ResponseWriter, r *http.Request) {
		result, err := backend.DNSRoutes(r.Context(), false)
		writeResult(w, result, err)
	})
	mux.HandleFunc("GET /v1/dns/routes/available", func(w http.ResponseWriter, r *http.Request) {
		result, err := backend.DNSRoutes(r.Context(), true)
		writeResult(w, result, err)
	})
	mux.HandleFunc("PUT /v1/dns/routes", func(w http.ResponseWriter, r *http.Request) {
		var request ReplaceDNSRoutesRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := backend.ReplaceDNSRoutes(r.Context(), request)
		writeResult(w, result, err)
	})
	mux.HandleFunc("PATCH /v1/dns/routes", func(w http.ResponseWriter, r *http.Request) {
		var request PatchDNSRoutesRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := backend.PatchDNSRoutes(r.Context(), request)
		writeResult(w, result, err)
	})
	mux.HandleFunc("DELETE /v1/dns/routes", func(w http.ResponseWriter, r *http.Request) {
		result, err := backend.ClearDNSRoutes(r.Context())
		writeResult(w, result, err)
	})

	mux.HandleFunc("GET /v1/dns/search-domains", func(w http.ResponseWriter, r *http.Request) {
		result, err := backend.SearchDomains(r.Context())
		writeResult(w, result, err)
	})
	mux.HandleFunc("PUT /v1/dns/search-domains", func(w http.ResponseWriter, r *http.Request) {
		var request ReplaceSearchDomainsRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := backend.ReplaceSearchDomains(r.Context(), request)
		writeResult(w, result, err)
	})
	mux.HandleFunc("PATCH /v1/dns/search-domains", func(w http.ResponseWriter, r *http.Request) {
		var request PatchSearchDomainsRequest
		if !decodeRequest(w, r, &request) {
			return
		}
		result, err := backend.PatchSearchDomains(r.Context(), request)
		writeResult(w, result, err)
	})
	mux.HandleFunc("DELETE /v1/dns/search-domains", func(w http.ResponseWriter, r *http.Request) {
		result, err := backend.ClearSearchDomains(r.Context())
		writeResult(w, result, err)
	})
	return mux
}

func profileActionHandler(backend Backend, action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name, err := url.PathUnescape(r.PathValue("name"))
		if err != nil {
			writeResult(w, nil, NewError("invalid_request", "invalid escaped profile name"))
			return
		}
		var result Profile
		switch action {
		case "enable":
			result, err = backend.SetProfileEnabled(r.Context(), name, true)
		case "disable":
			result, err = backend.SetProfileEnabled(r.Context(), name, false)
		case "restart":
			result, err = backend.RestartProfile(r.Context(), name)
		}
		writeResult(w, result, err)
	}
}

func decodeRequest(w http.ResponseWriter, r *http.Request, dst any) bool {
	defer r.Body.Close()
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		writeResult(w, nil, NewError("invalid_request", "decode request: %v", err))
		return false
	}
	if decoder.Decode(new(any)) != io.EOF {
		writeResult(w, nil, NewError("invalid_request", "request must contain one JSON value"))
		return false
	}
	return true
}

func writeResult(w http.ResponseWriter, result any, err error) {
	w.Header().Set("Content-Type", "application/json")
	if err != nil {
		var apiErr *Error
		if !errors.As(err, &apiErr) {
			apiErr = NewError("internal_error", "%v", err)
		}
		status := http.StatusBadRequest
		switch apiErr.Code {
		case "profile_not_found":
			status = http.StatusNotFound
		case "profile_exists", "profile_disabled", "transition_in_progress", "daemon_down",
			"route_binding_conflict", "dns_route_binding_conflict",
			"binding_profile_mismatch", "profile_has_bindings":
			status = http.StatusConflict
		case "permission_denied":
			status = http.StatusForbidden
		case "internal_error", "runtime_start_failed", "runtime_stop_failed", "dns_configuration_failed",
			"reconcile_failed", "purge_failed":
			status = http.StatusInternalServerError
		}
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(apiErr)
		return
	}
	_ = json.NewEncoder(w).Encode(result)
}
