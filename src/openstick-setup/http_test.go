package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeBackend struct {
	mu       sync.Mutex
	readyErr error
	applyErr error
	applied  []string
}

func (b *fakeBackend) ready() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.readyErr
}

func (b *fakeBackend) apply(password string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.applied = append(b.applied, password)
	return b.applyErr
}

func (b *fakeBackend) appliedPasswords() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.applied...)
}

func decodeSetupBody(t *testing.T, body string) (setupRequest, error) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "http://setup.invalid/apply", strings.NewReader(body))
	recorder := httptest.NewRecorder()
	return decodeSetup(recorder, req)
}

func TestDecodeSetupAcceptsOneBoundedCompleteObject(t *testing.T) {
	t.Parallel()
	validUnicode := strings.Repeat("密", 12)
	tests := []struct {
		name string
		body string
		want setupRequest
		ok   bool
	}{
		{
			name: "valid request",
			body: `{"password":"correct horse battery staple","confirmation":"correct horse battery staple"}`,
			want: setupRequest{Password: "correct horse battery staple", Confirmation: "correct horse battery staple"},
			ok:   true,
		},
		{
			name: "valid Unicode request",
			body: `{"password":"` + validUnicode + `","confirmation":"` + validUnicode + `"}`,
			want: setupRequest{Password: validUnicode, Confirmation: validUnicode},
			ok:   true,
		},
		{name: "missing confirmation", body: `{"password":"correct horse battery staple"}`},
		{name: "confirmation differs", body: `{"password":"correct horse battery staple","confirmation":"correct horse battery staplf"}`},
		{name: "unknown field", body: `{"password":"correct horse battery staple","confirmation":"correct horse battery staple","admin":true}`},
		{name: "wrong field type", body: `{"password":12,"confirmation":12}`},
		{name: "multiple JSON values", body: `{"password":"correct horse battery staple","confirmation":"correct horse battery staple"}{"password":"second value"}`},
		{name: "empty body", body: ``},
		{name: "malformed JSON", body: `{"password":`},
		{name: "larger than request limit", body: `{"password":"` + strings.Repeat("a", 5000) + `","confirmation":"` + strings.Repeat("a", 5000) + `"}`},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := decodeSetupBody(t, test.body)
			if test.ok {
				if err != nil || got != test.want {
					t.Fatalf("decodeSetup() = %#v, %v; want %#v, nil", got, err, test.want)
				}
				return
			}
			if !errors.Is(err, errPassword) {
				t.Fatalf("decodeSetup() error = %v, want errPassword", err)
			}
		})
	}
}

const (
	testSetupHost = "172.30.255.1:8080"
	testSetupPeer = "172.30.255.2"
)

func newWebHandlerForTest(backend setupBackend, done func()) *webHandler {
	return &webHandler{
		host:     testSetupHost,
		peer:     testSetupPeer,
		backend:  backend,
		done:     done,
		sessions: make(map[string]time.Time),
	}
}

func serveWebRequest(handler http.Handler, method, target, remote string, body string, configure func(*http.Request)) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, strings.NewReader(body))
	req.RemoteAddr = remote
	if configure != nil {
		configure(req)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	return recorder
}

func openSetupSession(t *testing.T, handler http.Handler) (string, *http.Cookie) {
	t.Helper()
	recorder := serveWebRequest(handler, http.MethodGet, "http://"+testSetupHost+"/api/session", testSetupPeer+":49152", "", nil)
	if recorder.Code != http.StatusOK {
		t.Fatalf("GET /api/session status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Token) != 64 {
		t.Fatalf("session token length = %d, want 64", len(response.Token))
	}
	cookies := recorder.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("session cookies = %d, want 1", len(cookies))
	}
	return response.Token, cookies[0]
}

func configureValidSetupRequest(token string, cookie *http.Cookie) func(*http.Request) {
	return func(req *http.Request) {
		req.Header.Set("Origin", "http://"+testSetupHost)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-CSRF-Token", token)
		req.AddCookie(cookie)
	}
}

func TestWebHandlerSessionAndSameOriginSetup(t *testing.T) {
	t.Parallel()
	backend := &fakeBackend{}
	doneCalls := 0
	handler := newWebHandlerForTest(backend, func() { doneCalls++ })
	token, cookie := openSetupSession(t, handler)

	if !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode || cookie.Path != "/" || cookie.MaxAge != 900 {
		t.Fatalf("unsafe session cookie: %#v", cookie)
	}
	body := `{"password":"correct horse battery staple","confirmation":"correct horse battery staple"}`
	recorder := serveWebRequest(handler, http.MethodPost, "http://"+testSetupHost+"/api/setup", testSetupPeer+":49153", body, configureValidSetupRequest(token, cookie))
	if recorder.Code != http.StatusOK {
		t.Fatalf("POST /api/setup status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	if got := backend.appliedPasswords(); len(got) != 1 || got[0] != "correct horse battery staple" {
		t.Fatalf("backend passwords = %q", got)
	}
	if doneCalls != 1 {
		t.Fatalf("done called %d times, want 1", doneCalls)
	}
	for header, want := range map[string]string{
		"Cache-Control":          "no-store",
		"X-Content-Type-Options": "nosniff",
		"X-Frame-Options":        "DENY",
		"Referrer-Policy":        "no-referrer",
	} {
		if got := recorder.Header().Get(header); got != want {
			t.Errorf("%s = %q, want %q", header, got, want)
		}
	}
}

func TestWebHandlerRejectsRequestsOutsideUSBAndSameOriginBoundary(t *testing.T) {
	t.Parallel()
	body := `{"password":"correct horse battery staple","confirmation":"correct horse battery staple"}`
	tests := []struct {
		name       string
		target     string
		remote     string
		configure  func(*http.Request, string, *http.Cookie)
		mutate     func(*webHandler, string)
		wantStatus int
	}{
		{name: "wrong Host", target: "http://172.30.255.10:8080/api/setup", remote: testSetupPeer + ":49153", wantStatus: http.StatusForbidden},
		{
			name: "Host suffix", target: "http://" + testSetupHost + "/api/setup", remote: testSetupPeer + ":49153",
			configure: func(req *http.Request, token string, cookie *http.Cookie) {
				configureValidSetupRequest(token, cookie)(req)
				req.Host = testSetupHost + ".example"
			},
			wantStatus: http.StatusForbidden,
		},
		{name: "wrong peer", target: "http://" + testSetupHost + "/api/setup", remote: "172.30.255.3:49153", wantStatus: http.StatusForbidden},
		{name: "malformed peer", target: "http://" + testSetupHost + "/api/setup", remote: testSetupPeer, wantStatus: http.StatusForbidden},
		{
			name: "missing Origin", target: "http://" + testSetupHost + "/api/setup", remote: testSetupPeer + ":49153",
			configure: func(req *http.Request, token string, cookie *http.Cookie) {
				configureValidSetupRequest(token, cookie)(req)
				req.Header.Del("Origin")
			},
			wantStatus: http.StatusForbidden,
		},
		{
			name: "foreign Origin", target: "http://" + testSetupHost + "/api/setup", remote: testSetupPeer + ":49153",
			configure: func(req *http.Request, token string, cookie *http.Cookie) {
				configureValidSetupRequest(token, cookie)(req)
				req.Header.Set("Origin", "http://evil.example")
			},
			wantStatus: http.StatusForbidden,
		},
		{
			name: "wrong content type", target: "http://" + testSetupHost + "/api/setup", remote: testSetupPeer + ":49153",
			configure: func(req *http.Request, token string, cookie *http.Cookie) {
				configureValidSetupRequest(token, cookie)(req)
				req.Header.Set("Content-Type", "text/plain")
			},
			wantStatus: http.StatusUnsupportedMediaType,
		},
		{
			name: "missing session cookie", target: "http://" + testSetupHost + "/api/setup", remote: testSetupPeer + ":49153",
			configure: func(req *http.Request, token string, _ *http.Cookie) {
				req.Header.Set("Origin", "http://"+testSetupHost)
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("X-CSRF-Token", token)
			},
			wantStatus: http.StatusForbidden,
		},
		{
			name: "CSRF token not bound to cookie", target: "http://" + testSetupHost + "/api/setup", remote: testSetupPeer + ":49153",
			configure: func(req *http.Request, _ string, cookie *http.Cookie) {
				configureValidSetupRequest(strings.Repeat("0", 64), cookie)(req)
			},
			wantStatus: http.StatusForbidden,
		},
		{
			name: "unknown session cookie", target: "http://" + testSetupHost + "/api/setup", remote: testSetupPeer + ":49153",
			configure: func(req *http.Request, token string, cookie *http.Cookie) {
				copy := *cookie
				copy.Value = strings.Repeat("0", 64)
				configureValidSetupRequest(token, &copy)(req)
			},
			wantStatus: http.StatusForbidden,
		},
		{
			name: "expired session", target: "http://" + testSetupHost + "/api/setup", remote: testSetupPeer + ":49153",
			configure: func(req *http.Request, token string, cookie *http.Cookie) {
				configureValidSetupRequest(token, cookie)(req)
			},
			mutate:     func(handler *webHandler, token string) { handler.sessions[token] = time.Now().Add(-time.Second) },
			wantStatus: http.StatusForbidden,
		},
		{
			name: "query string", target: "http://" + testSetupHost + "/api/setup?next=1", remote: testSetupPeer + ":49153",
			configure: func(req *http.Request, token string, cookie *http.Cookie) {
				configureValidSetupRequest(token, cookie)(req)
			},
			wantStatus: http.StatusBadRequest,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			backend := &fakeBackend{}
			handler := newWebHandlerForTest(backend, func() {})
			token, cookie := openSetupSession(t, handler)
			if test.mutate != nil {
				test.mutate(handler, token)
			}
			configure := func(req *http.Request) {
				if test.configure != nil {
					test.configure(req, token, cookie)
				} else {
					configureValidSetupRequest(token, cookie)(req)
				}
			}
			recorder := serveWebRequest(handler, http.MethodPost, test.target, test.remote, body, configure)
			if recorder.Code != test.wantStatus {
				t.Fatalf("status = %d, want %d; body = %s", recorder.Code, test.wantStatus, recorder.Body.String())
			}
			if got := backend.appliedPasswords(); len(got) != 0 {
				t.Fatalf("rejected request reached backend with %q", got)
			}
		})
	}
}

func TestWebHandlerDoesNotIssueSessionAfterConfiguration(t *testing.T) {
	t.Parallel()
	backend := &fakeBackend{readyErr: errConfigured}
	handler := newWebHandlerForTest(backend, func() {})
	recorder := serveWebRequest(handler, http.MethodGet, "http://"+testSetupHost+"/api/session", testSetupPeer+":49152", "", nil)
	if recorder.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409", recorder.Code)
	}
	if cookies := recorder.Result().Cookies(); len(cookies) != 0 {
		t.Fatalf("configured service issued %d cookies", len(cookies))
	}
}
