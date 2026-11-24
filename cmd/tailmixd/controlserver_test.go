package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/maisem/tailmix/controlapi"
	"tailscale.com/safesocket"
)

type controlServerTestBackend struct {
	controlapi.Backend
	addCalls int
}

func (b *controlServerTestBackend) ListProfiles(context.Context, bool) (controlapi.Profiles, error) {
	return controlapi.Profiles{Profiles: []controlapi.Profile{{Name: "work"}}}, nil
}

func (b *controlServerTestBackend) AddProfile(_ context.Context, request controlapi.AddProfileRequest) (controlapi.Profile, error) {
	b.addCalls++
	return controlapi.Profile{Name: request.Name}, nil
}

func TestControlServerAllowsReadsAndAuthorizesMutations(t *testing.T) {
	if !safesocket.PlatformUsesPeerCreds() {
		t.Skip("platform does not support Unix peer credentials")
	}
	socketDir, err := os.MkdirTemp("/tmp", "tailmix-control-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(socketDir) })

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	backend := &controlServerTestBackend{}
	server, err := startControlServer(ctx, socketDir, backend)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	info, err := os.Stat(server.path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0666 {
		t.Fatalf("control socket mode = %04o, want 0666", got)
	}

	client := controlapi.NewClient(socketDir)
	profiles, err := client.Profiles(ctx, false)
	if err != nil {
		t.Fatalf("read profiles: %v", err)
	}
	if len(profiles.Profiles) != 1 || profiles.Profiles[0].Name != "work" {
		t.Fatalf("profiles = %+v", profiles.Profiles)
	}

	_, err = client.AddProfile(ctx, controlapi.AddProfileRequest{Name: "home"})
	if os.Geteuid() == 0 {
		if err != nil {
			t.Fatalf("root mutation: %v", err)
		}
		if backend.addCalls != 1 {
			t.Fatalf("add calls = %d, want 1", backend.addCalls)
		}
		return
	}
	apiErr, ok := err.(*controlapi.Error)
	if !ok || apiErr.Code != "permission_denied" {
		t.Fatalf("non-root mutation error = %v, want permission_denied", err)
	}
	if backend.addCalls != 0 {
		t.Fatalf("add calls = %d, want 0", backend.addCalls)
	}
}

func TestAuthorizeMutations(t *testing.T) {
	tests := []struct {
		name       string
		method     string
		path       string
		uid        string
		operator   string
		wantStatus int
		wantCalled bool
	}{
		{
			name:       "read without credentials",
			method:     http.MethodGet,
			wantStatus: http.StatusNoContent,
			wantCalled: true,
		},
		{
			name:       "root mutation",
			method:     http.MethodPatch,
			uid:        "0",
			wantStatus: http.StatusNoContent,
			wantCalled: true,
		},
		{
			name:       "non-root mutation",
			method:     http.MethodPost,
			uid:        "501",
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "mutation without credentials",
			method:     http.MethodDelete,
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "operator connects profile",
			method:     http.MethodPost,
			path:       "/v1/profiles/by-name/work/enable",
			uid:        "501",
			operator:   "501",
			wantStatus: http.StatusNoContent,
			wantCalled: true,
		},
		{
			name:       "operator disconnects escaped profile",
			method:     http.MethodPost,
			path:       "/v1/profiles/by-name/my%20home/disable",
			uid:        "501",
			operator:   "501",
			wantStatus: http.StatusNoContent,
			wantCalled: true,
		},
		{
			name:       "operator selects exit node",
			method:     http.MethodPut,
			path:       "/v1/exit-node",
			uid:        "501",
			operator:   "501",
			wantStatus: http.StatusNoContent,
			wantCalled: true,
		},
		{
			name:       "operator clears exit node",
			method:     http.MethodDelete,
			path:       "/v1/exit-node",
			uid:        "501",
			operator:   "501",
			wantStatus: http.StatusNoContent,
			wantCalled: true,
		},
		{
			name:       "operator cannot remove profile",
			method:     http.MethodDelete,
			path:       "/v1/profiles/by-name/work",
			uid:        "501",
			operator:   "501",
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "operator cannot restart profile",
			method:     http.MethodPost,
			path:       "/v1/profiles/by-name/work/restart",
			uid:        "501",
			operator:   "501",
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "operator cannot change operator",
			method:     http.MethodPut,
			path:       "/v1/operator",
			uid:        "501",
			operator:   "501",
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "operator cannot accept routes",
			method:     http.MethodPatch,
			path:       "/v1/routes",
			uid:        "501",
			operator:   "501",
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "other user cannot use operator routes",
			method:     http.MethodPut,
			path:       "/v1/exit-node",
			uid:        "502",
			operator:   "501",
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "operator routes need credentials",
			method:     http.MethodPut,
			path:       "/v1/exit-node",
			wantStatus: http.StatusForbidden,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			called := false
			handler := authorizeMutations(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				called = true
				w.WriteHeader(http.StatusNoContent)
			}), func() string { return test.operator })
			path := test.path
			if path == "" {
				path = "/v1/test"
			}
			request := httptest.NewRequest(test.method, path, nil)
			if test.uid != "" {
				request = request.WithContext(context.WithValue(
					request.Context(), peerUIDContextKey{}, test.uid))
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)

			if response.Code != test.wantStatus {
				t.Fatalf("status = %d, want %d", response.Code, test.wantStatus)
			}
			if called != test.wantCalled {
				t.Fatalf("next handler called = %t, want %t", called, test.wantCalled)
			}
			if test.wantStatus == http.StatusForbidden {
				var got controlapi.Error
				if err := json.NewDecoder(response.Body).Decode(&got); err != nil {
					t.Fatal(err)
				}
				if got.Code != "permission_denied" {
					t.Fatalf("error = %+v, want permission_denied", got)
				}
			}
		})
	}
}
