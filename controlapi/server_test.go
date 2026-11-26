package controlapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"

	tailmixversion "github.com/maisem/tailmix/version"
	"github.com/maisem/tailmix/wireguardcfg"
)

type recordingBackend struct {
	Backend
	daemonUp         bool
	ipPatch          PatchIPRoutesRequest
	exitRequest      SetExitNodeRequest
	profiles         Profiles
	status           Status
	update           UpdateStatus
	updateAction     string
	wireGuardConfig  wireguardcfg.Config
	wireGuardSecrets wireguardcfg.Secrets
	wireGuardProfile WireGuardProfile
	wireGuardName    string
	wireGuardShields bool
}

func (b *recordingBackend) UpdateStatus(context.Context) (UpdateStatus, error) { return b.update, nil }
func (b *recordingBackend) SetUpdatesEnabled(_ context.Context, enabled bool) (UpdateStatus, error) {
	if enabled {
		b.updateAction = "enable"
	} else {
		b.updateAction = "disable"
	}
	b.update.Enabled = enabled
	return b.update, nil
}
func (b *recordingBackend) CheckForUpdate(context.Context) (UpdateStatus, error) {
	b.updateAction = "check"
	return b.update, nil
}
func (b *recordingBackend) ApplyUpdate(context.Context) (UpdateStatus, error) {
	b.updateAction = "apply"
	return b.update, nil
}

func (b *recordingBackend) Status(context.Context) (Status, error) {
	return b.status, nil
}

func (b *recordingBackend) SetDaemonUp(_ context.Context, up bool) (DaemonState, error) {
	b.daemonUp = up
	state := "down"
	if up {
		state = "up"
	}
	return DaemonState{State: state}, nil
}

func (b *recordingBackend) PatchIPRoutes(_ context.Context, request PatchIPRoutesRequest) (IPRoutes, error) {
	b.ipPatch = request
	return IPRoutes{Bindings: []IPRouteBinding{{
		Prefix:      request.Bind[0].Prefix,
		ProfileName: request.Bind[0].ProfileName,
		State:       "installed",
	}}}, nil
}

func (b *recordingBackend) ListProfiles(context.Context, bool) (Profiles, error) {
	return b.profiles, nil
}

func (b *recordingBackend) SetExitNode(_ context.Context, request SetExitNodeRequest) (ExitNodes, error) {
	b.exitRequest = request
	return ExitNodes{Selected: &SelectedExitNode{
		ProfileName: request.ProfileName,
		DNSName:     request.Peer,
		State:       "installed",
	}}, nil
}

func (b *recordingBackend) ApplyWireGuard(_ context.Context, config wireguardcfg.Config, secrets wireguardcfg.Secrets) (WireGuardProfile, error) {
	b.wireGuardConfig = config
	b.wireGuardSecrets = secrets
	return b.wireGuardProfile, nil
}

func (b *recordingBackend) WireGuardProfile(_ context.Context, name string) (WireGuardProfile, error) {
	b.wireGuardName = name
	return b.wireGuardProfile, nil
}

func (b *recordingBackend) SetWireGuardShieldsUp(_ context.Context, name string, enabled bool) (WireGuardProfile, error) {
	b.wireGuardName = name
	b.wireGuardShields = enabled
	b.wireGuardProfile.ShieldsUp = enabled
	return b.wireGuardProfile, nil
}

func TestHandlerReturnsServerVersion(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/v1/version", nil)
	response := httptest.NewRecorder()
	Handler(&recordingBackend{}).ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	var got tailmixversion.Meta
	if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.Short == "" || got.Long == "" || got.TailscaleVersion == "" {
		t.Fatalf("version = %+v", got)
	}
}

func TestHandlerChangesDaemonState(t *testing.T) {
	for _, test := range []struct {
		path string
		up   bool
	}{
		{path: "/v1/up", up: true},
		{path: "/v1/down", up: false},
	} {
		t.Run(test.path, func(t *testing.T) {
			backend := &recordingBackend{}
			response := httptest.NewRecorder()
			Handler(backend).ServeHTTP(response, httptest.NewRequest(http.MethodPost, test.path, nil))
			if response.Code != http.StatusOK {
				t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
			}
			if backend.daemonUp != test.up {
				t.Fatalf("daemon up = %v, want %v", backend.daemonUp, test.up)
			}
			var got DaemonState
			if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
				t.Fatal(err)
			}
			want := "down"
			if test.up {
				want = "up"
			}
			if got.State != want {
				t.Fatalf("state = %q, want %q", got.State, want)
			}
		})
	}
}

func TestHandlerAppliesAndShowsWireGuardProfile(t *testing.T) {
	private, err := wireguardcfg.GeneratePrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	backend := &recordingBackend{wireGuardProfile: WireGuardProfile{
		Name: "lab", Kind: "wireguard", PublicKey: "public",
		Peers: []WireGuardPeer{{Name: "peer", PublicKey: "peer-public", Addresses: []netip.Addr{netip.MustParseAddr("10.0.0.2")}}},
	}}
	body, err := json.Marshal(ApplyWireGuardRequest{
		Config:  wireguardcfg.Config{Version: 1, Name: "lab", DNSSuffix: "wg.example", Addresses: []netip.Addr{netip.MustParseAddr("10.0.0.1")}},
		Secrets: wireguardcfg.Secrets{PrivateKey: &private},
	})
	if err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	Handler(backend).ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/v1/wireguard", strings.NewReader(string(body))))
	if response.Code != http.StatusOK || backend.wireGuardConfig.Name != "lab" || backend.wireGuardSecrets.PrivateKey == nil || *backend.wireGuardSecrets.PrivateKey != private {
		t.Fatalf("status = %d, config = %+v, secrets = %+v, body = %s", response.Code, backend.wireGuardConfig, backend.wireGuardSecrets, response.Body.String())
	}
	if strings.Contains(response.Body.String(), private.String()) {
		t.Fatalf("response exposed private key: %s", response.Body.String())
	}
	if strings.Contains(response.Body.String(), "lastHandshake") || !strings.Contains(response.Body.String(), `"canonicalAddresses":["10.0.0.2"]`) {
		t.Fatalf("response did not preserve optional/runtime address contract: %s", response.Body.String())
	}

	response = httptest.NewRecorder()
	Handler(backend).ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1/wireguard/by-name/lab", nil))
	if response.Code != http.StatusOK || backend.wireGuardName != "lab" || !strings.Contains(response.Body.String(), `"kind":"wireguard"`) {
		t.Fatalf("status = %d, name = %q, body = %s", response.Code, backend.wireGuardName, response.Body.String())
	}

	response = httptest.NewRecorder()
	Handler(backend).ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/v1/wireguard/by-name/lab/shields-up", strings.NewReader(`{"enabled":true}`)))
	if response.Code != http.StatusOK || backend.wireGuardName != "lab" || !backend.wireGuardShields || !strings.Contains(response.Body.String(), `"shieldsUp":true`) {
		t.Fatalf("status = %d, name = %q, enabled = %v, body = %s", response.Code, backend.wireGuardName, backend.wireGuardShields, response.Body.String())
	}
}

func TestHandlerReturnsAggregateStatus(t *testing.T) {
	backend := &recordingBackend{status: Status{
		State:    "down",
		Profiles: []Profile{{Name: "work"}},
		DNSRoutes: DNSRoutes{Automatic: []DNSRouteBinding{{
			Domain: "work.example", ProfileName: "work", State: "installed",
		}}},
	}}
	request := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	response := httptest.NewRecorder()
	Handler(backend).ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	var got Status
	if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.State != "down" || len(got.Profiles) != 1 || got.Profiles[0].Name != "work" ||
		len(got.DNSRoutes.Automatic) != 1 || got.DNSRoutes.Automatic[0].Domain != "work.example" {
		t.Fatalf("aggregate status = %+v", got)
	}
}

func TestHandlerUpdateEndpoints(t *testing.T) {
	for _, tc := range []struct{ path, action string }{
		{"/v1/update/enable", "enable"},
		{"/v1/update/disable", "disable"},
		{"/v1/update/check", "check"},
		{"/v1/update/apply", "apply"},
	} {
		t.Run(tc.action, func(t *testing.T) {
			backend := &recordingBackend{update: UpdateStatus{CurrentVersion: "1.2.3", State: "idle"}}
			response := httptest.NewRecorder()
			Handler(backend).ServeHTTP(response, httptest.NewRequest(http.MethodPost, tc.path, nil))
			if response.Code != http.StatusOK {
				t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
			}
			if backend.updateAction != tc.action {
				t.Fatalf("action = %q", backend.updateAction)
			}
		})
	}
	backend := &recordingBackend{update: UpdateStatus{Enabled: true, State: "idle"}}
	response := httptest.NewRecorder()
	Handler(backend).ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1/update", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d", response.Code)
	}
	var got UpdateStatus
	if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if !got.Enabled {
		t.Fatalf("status = %+v", got)
	}
}

func TestHandlerDecodesAtomicRoutePatch(t *testing.T) {
	backend := &recordingBackend{}
	request := httptest.NewRequest(http.MethodPatch, "/v1/routes", strings.NewReader(`{
		"bind":[{"prefix":"10.20.0.0/16","profileName":"work"}],
		"acceptAll":{"home":true}
	}`))
	response := httptest.NewRecorder()
	Handler(backend).ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	if len(backend.ipPatch.Bind) != 1 ||
		backend.ipPatch.Bind[0].Prefix != netip.MustParsePrefix("10.20.0.0/16") ||
		backend.ipPatch.Bind[0].ProfileName != "work" ||
		!backend.ipPatch.AcceptAll["home"] {
		t.Fatalf("patch = %+v", backend.ipPatch)
	}
	var got IPRoutes
	if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.Bindings[0].State != "installed" {
		t.Fatalf("response = %+v", got)
	}
}

func TestHandlerRejectsUnknownRequestFields(t *testing.T) {
	backend := &recordingBackend{}
	request := httptest.NewRequest(http.MethodPatch, "/v1/routes", strings.NewReader(`{"surprise":true}`))
	response := httptest.NewRecorder()
	Handler(backend).ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	var got Error
	if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.Code != "invalid_request" {
		t.Fatalf("error = %+v", got)
	}
}

func TestHandlerSetsExitNode(t *testing.T) {
	backend := &recordingBackend{}
	request := httptest.NewRequest(http.MethodPut, "/v1/exit-node", strings.NewReader(`{
		"profileName":"work",
		"peer":"gateway"
	}`))
	response := httptest.NewRecorder()
	Handler(backend).ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	if backend.exitRequest.ProfileName != "work" || backend.exitRequest.Peer != "gateway" {
		t.Fatalf("request = %+v", backend.exitRequest)
	}
	var got ExitNodes
	if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.Selected == nil || got.Selected.State != "installed" {
		t.Fatalf("response = %+v", got)
	}
}

func TestHandlerRejectsRemovedProfileControlURL(t *testing.T) {
	backend := &recordingBackend{}
	request := httptest.NewRequest(http.MethodPost, "/v1/profiles", strings.NewReader(`{
		"name":"work",
		"controlUrl":"https://headscale.example.com"
	}`))
	response := httptest.NewRecorder()
	Handler(backend).ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	var got Error
	if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.Code != "invalid_request" {
		t.Fatalf("error = %+v", got)
	}
}

func TestHandlerMapsDaemonDownToHTTPConflict(t *testing.T) {
	backend := &daemonDownBackend{recordingBackend: recordingBackend{}}
	request := httptest.NewRequest(http.MethodPost, "/v1/profiles", strings.NewReader(`{"name":"work"}`))
	response := httptest.NewRecorder()
	Handler(backend).ServeHTTP(response, request)
	if response.Code != http.StatusConflict {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	var got Error
	if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.Code != "daemon_down" {
		t.Fatalf("error = %+v", got)
	}
}

type daemonDownBackend struct {
	recordingBackend
}

func (b *daemonDownBackend) AddProfile(context.Context, AddProfileRequest) (Profile, error) {
	return Profile{}, NewError("daemon_down", "tailmix is down")
}

func TestHandlerMapsConflictsToHTTPConflict(t *testing.T) {
	backend := &conflictBackend{recordingBackend: recordingBackend{}}
	request := httptest.NewRequest(http.MethodPatch, "/v1/routes", strings.NewReader(`{
		"bind":[{"prefix":"10.20.0.0/16","profileName":"work"}]
	}`))
	response := httptest.NewRecorder()
	Handler(backend).ServeHTTP(response, request)
	if response.Code != http.StatusConflict {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
}

type conflictBackend struct {
	recordingBackend
}

func (b *conflictBackend) PatchIPRoutes(context.Context, PatchIPRoutesRequest) (IPRoutes, error) {
	return IPRoutes{}, NewError("route_binding_conflict", "already bound")
}

type operatorBackend struct {
	recordingBackend
	operator Operator
}

func (b *operatorBackend) Operator(context.Context) (Operator, error) { return b.operator, nil }
func (b *operatorBackend) SetOperator(_ context.Context, request SetOperatorRequest) (Operator, error) {
	b.operator = Operator{UID: request.UID}
	return b.operator, nil
}
func (b *operatorBackend) ClearOperator(context.Context) (Operator, error) {
	b.operator = Operator{}
	return b.operator, nil
}

func TestHandlerOperatorEndpoints(t *testing.T) {
	backend := &operatorBackend{}
	handler := Handler(backend)
	serve := func(method, body string) (int, Operator) {
		t.Helper()
		request := httptest.NewRequest(method, "/v1/operator", strings.NewReader(body))
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		var got Operator
		if response.Code == http.StatusOK {
			if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
				t.Fatal(err)
			}
		}
		return response.Code, got
	}
	if code, got := serve(http.MethodPut, `{"uid":"501"}`); code != http.StatusOK || got.UID != "501" {
		t.Fatalf("PUT = %d %+v", code, got)
	}
	if code, got := serve(http.MethodGet, ""); code != http.StatusOK || got.UID != "501" {
		t.Fatalf("GET = %d %+v", code, got)
	}
	if code, got := serve(http.MethodDelete, ""); code != http.StatusOK || got.UID != "" {
		t.Fatalf("DELETE = %d %+v", code, got)
	}

	unsupported := httptest.NewRecorder()
	Handler(&recordingBackend{}).ServeHTTP(unsupported, httptest.NewRequest(http.MethodGet, "/v1/operator", nil))
	if unsupported.Code != http.StatusBadRequest {
		t.Fatalf("unsupported GET = %d", unsupported.Code)
	}
}

type locationBackend struct {
	recordingBackend
	call     string
	name     string
	gateway  string
	enabled  bool
	override string
}

func (b *locationBackend) result() Profile {
	return Profile{Name: b.name, RoutesInEffect: true, Location: &ProfileLocation{Enabled: true, Current: "home"}}
}

func (b *locationBackend) SetProfileLocation(_ context.Context, name string, request SetLocationRequest) (Profile, error) {
	b.call, b.name, b.enabled = "SetProfileLocation", name, request.Enabled
	return b.result(), nil
}

func (b *locationBackend) MarkCurrentNetworkHome(_ context.Context, name string) (Profile, error) {
	b.call, b.name = "MarkCurrentNetworkHome", name
	return b.result(), nil
}

func (b *locationBackend) ForgetHomeNetwork(_ context.Context, name, gateway string) (Profile, error) {
	b.call, b.name, b.gateway = "ForgetHomeNetwork", name, gateway
	return b.result(), nil
}

func (b *locationBackend) SetLocationOverride(_ context.Context, name string, request SetLocationOverrideRequest) (Profile, error) {
	b.call, b.name, b.override = "SetLocationOverride", name, request.Routes
	return b.result(), nil
}

func (b *locationBackend) ClearLocationOverride(_ context.Context, name string) (Profile, error) {
	b.call, b.name = "ClearLocationOverride", name
	return b.result(), nil
}

func TestHandlerLocationEndpoints(t *testing.T) {
	for _, tc := range []struct {
		method, path, body string
		want               locationBackend
	}{
		{http.MethodPut, "/v1/profiles/by-name/my%20work/location", `{"enabled":true}`,
			locationBackend{call: "SetProfileLocation", name: "my work", enabled: true}},
		{http.MethodPost, "/v1/profiles/by-name/my%20work/location/home-networks/current", "",
			locationBackend{call: "MarkCurrentNetworkHome", name: "my work"}},
		{http.MethodDelete, "/v1/profiles/by-name/my%20work/location/home-networks/current", "",
			locationBackend{call: "ForgetHomeNetwork", name: "my work", gateway: "current"}},
		{http.MethodDelete, "/v1/profiles/by-name/my%20work/location/home-networks/aa%3Abb%3Acc%3Add%3Aee%3Aff", "",
			locationBackend{call: "ForgetHomeNetwork", name: "my work", gateway: "aa:bb:cc:dd:ee:ff"}},
		{http.MethodPut, "/v1/profiles/by-name/my%20work/location/override", `{"routes":"off"}`,
			locationBackend{call: "SetLocationOverride", name: "my work", override: "off"}},
		{http.MethodDelete, "/v1/profiles/by-name/my%20work/location/override", "",
			locationBackend{call: "ClearLocationOverride", name: "my work"}},
	} {
		t.Run(tc.method+" "+tc.path, func(t *testing.T) {
			backend := &locationBackend{}
			response := httptest.NewRecorder()
			Handler(backend).ServeHTTP(response, httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body)))
			if response.Code != http.StatusOK {
				t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
			}
			if backend.call != tc.want.call || backend.name != tc.want.name || backend.gateway != tc.want.gateway ||
				backend.enabled != tc.want.enabled || backend.override != tc.want.override {
				t.Fatalf("backend = %+v, want %+v", *backend, tc.want)
			}
			var got Profile
			if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
				t.Fatal(err)
			}
			if got.Name != "my work" || !got.RoutesInEffect || got.Location == nil || got.Location.Current != "home" {
				t.Fatalf("profile = %+v", got)
			}

			unsupported := httptest.NewRecorder()
			Handler(&recordingBackend{}).ServeHTTP(unsupported, httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body)))
			var apiErr Error
			if err := json.NewDecoder(unsupported.Body).Decode(&apiErr); err != nil {
				t.Fatal(err)
			}
			if unsupported.Code != http.StatusBadRequest || apiErr.Code != "unsupported" {
				t.Fatalf("unsupported = %d %+v", unsupported.Code, apiErr)
			}
		})
	}
}

func TestOperatorRoutesLocation(t *testing.T) {
	routes := OperatorRoutes()
	for _, tc := range []struct {
		method, path string
		allowed      bool
	}{
		{http.MethodPost, "/v1/profiles/by-name/work/location/home-networks/current", true},
		{http.MethodDelete, "/v1/profiles/by-name/work/location/home-networks/current", true},
		{http.MethodPut, "/v1/profiles/by-name/work/location/override", true},
		{http.MethodDelete, "/v1/profiles/by-name/work/location/override", true},
		{http.MethodPut, "/v1/profiles/by-name/work/location", false},
		{http.MethodDelete, "/v1/profiles/by-name/work/location/home-networks/aa:bb:cc:dd:ee:ff", false},
		{http.MethodDelete, "/v1/profiles/by-name/work/location/home-networks/aa%3Abb%3Acc%3Add%3Aee%3Aff", false},
	} {
		_, pattern := routes.Handler(httptest.NewRequest(tc.method, tc.path, nil))
		if (pattern != "") != tc.allowed {
			t.Errorf("%s %s: pattern = %q, want allowed = %v", tc.method, tc.path, pattern, tc.allowed)
		}
	}
}

type handlerTransport struct{ handler http.Handler }

func (t handlerTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response := httptest.NewRecorder()
	t.handler.ServeHTTP(response, request)
	return response.Result(), nil
}

func TestClientLocationMethods(t *testing.T) {
	backend := &locationBackend{}
	client := &Client{http: &http.Client{Transport: handlerTransport{Handler(backend)}}}
	ctx := context.Background()

	got, err := client.SetProfileLocation(ctx, "my work", SetLocationRequest{Enabled: true})
	if err != nil || backend.call != "SetProfileLocation" || backend.name != "my work" || !backend.enabled ||
		got.Location == nil || got.Location.Current != "home" {
		t.Fatalf("SetProfileLocation = %+v, %v; backend = %+v", got, err, *backend)
	}
	if _, err := client.MarkCurrentNetworkHome(ctx, "my work"); err != nil || backend.call != "MarkCurrentNetworkHome" || backend.name != "my work" {
		t.Fatalf("MarkCurrentNetworkHome: %v; backend = %+v", err, *backend)
	}
	if _, err := client.ForgetHomeNetwork(ctx, "my work", "aa:bb:cc:dd:ee:ff"); err != nil ||
		backend.call != "ForgetHomeNetwork" || backend.gateway != "aa:bb:cc:dd:ee:ff" {
		t.Fatalf("ForgetHomeNetwork: %v; backend = %+v", err, *backend)
	}
	if _, err := client.ForgetHomeNetwork(ctx, "my work", "current"); err != nil || backend.gateway != "current" {
		t.Fatalf("ForgetHomeNetwork current: %v; backend = %+v", err, *backend)
	}
	if _, err := client.SetLocationOverride(ctx, "my work", SetLocationOverrideRequest{Routes: "on"}); err != nil ||
		backend.call != "SetLocationOverride" || backend.override != "on" {
		t.Fatalf("SetLocationOverride: %v; backend = %+v", err, *backend)
	}
	if _, err := client.ClearLocationOverride(ctx, "my work"); err != nil || backend.call != "ClearLocationOverride" {
		t.Fatalf("ClearLocationOverride: %v; backend = %+v", err, *backend)
	}

	unsupported := &Client{http: &http.Client{Transport: handlerTransport{Handler(&recordingBackend{})}}}
	_, err = unsupported.ClearLocationOverride(ctx, "my work")
	var apiErr *Error
	if !errors.As(err, &apiErr) || apiErr.Code != "unsupported" {
		t.Fatalf("unsupported error = %v", err)
	}
}
