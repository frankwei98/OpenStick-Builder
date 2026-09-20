package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"sync"
	"time"
)

//go:embed web/*
var assets embed.FS

type setupRequest struct {
	Password     string `json:"password"`
	Confirmation string `json:"confirmation"`
}

type setupBackend interface {
	ready() error
	apply(string) error
}

type helperClient struct{ client *http.Client }

func newHelperClient(path string) *helperClient {
	return &helperClient{&http.Client{
		Timeout: 25 * time.Second,
		Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", path)
		}},
	}}
}
func (h *helperClient) call(method, path string, body []byte) error {
	req, err := http.NewRequest(method, "http://helper"+path, bytes.NewReader(body))
	if err != nil {
		return errUnavailable
	}
	res, err := h.client.Do(req)
	if err != nil {
		return errUnavailable
	}
	defer res.Body.Close()
	switch res.StatusCode {
	case http.StatusOK:
		return nil
	case http.StatusConflict:
		return errConfigured
	case http.StatusBadRequest:
		return errPassword
	default:
		return errUnavailable
	}
}
func (h *helperClient) ready() error { return h.call("GET", "/ready", nil) }
func (h *helperClient) apply(password string) error {
	body, _ := json.Marshal(setupRequest{Password: password, Confirmation: password})
	return h.call("POST", "/apply", body)
}

func decodeSetup(w http.ResponseWriter, r *http.Request) (setupRequest, error) {
	var value setupRequest
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&value); err != nil {
		return value, errPassword
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return value, errPassword
	}
	if err := validatePassword(value.Password); err != nil {
		return value, err
	}
	if value.Password != value.Confirmation {
		return value, errPassword
	}
	return value, nil
}

func reply(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": code})
}

func helperHandler(p *provisioner, done func()) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/ready" && r.Method == "GET" {
			p.mu.Lock()
			state, err := p.status()
			failed := p.failed
			p.mu.Unlock()
			if err != nil || failed {
				reply(w, 503, "unavailable")
				return
			}
			if state == "configured" {
				reply(w, 409, "configured")
				return
			}
			if state != "unconfigured" {
				reply(w, 503, "unavailable")
				return
			}
			reply(w, 200, "ready")
			return
		}
		if r.URL.Path != "/apply" || r.Method != "POST" {
			http.NotFound(w, r)
			return
		}
		input, err := decodeSetup(w, r)
		if err == nil {
			err = p.apply(input.Password)
		}
		switch {
		case err == nil:
			reply(w, 200, "configured")
			done()
		case errors.Is(err, errConfigured):
			reply(w, 409, "configured")
		case errors.Is(err, errPassword):
			reply(w, 400, "invalid_password")
		default:
			reply(w, 503, "unavailable")
		}
	})
}

type webHandler struct {
	host, peer string
	backend    setupBackend
	done       func()
	mu         sync.Mutex
	// Bounded session store: visiting the page does not evict other sessions.
	sessions    map[string]time.Time
	lastAttempt time.Time
}

func randomToken() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("random source unavailable")
	}
	return hex.EncodeToString(b[:])
}
func (h *webHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || peer != h.peer || r.Host != h.host {
		reply(w, 403, "forbidden")
		return
	}
	if r.URL.RawQuery != "" {
		reply(w, 400, "invalid_request")
		return
	}
	if r.Method == "GET" {
		var file, contentType string
		switch r.URL.Path {
		case "/":
			file = "index.html"
			contentType = "text/html; charset=utf-8"
		case "/style.css":
			file = "style.css"
			contentType = "text/css; charset=utf-8"
		case "/app.js":
			file = "app.js"
			contentType = "text/javascript; charset=utf-8"
		case "/api/session":
			if err := h.backend.ready(); err != nil {
				if errors.Is(err, errConfigured) {
					reply(w, 409, "configured")
				} else {
					reply(w, 503, "unavailable")
				}
				return
			}
			h.mu.Lock()
			now := time.Now()
			for token, expiry := range h.sessions {
				if now.After(expiry) {
					delete(h.sessions, token)
				}
			}
			if len(h.sessions) >= 32 {
				h.mu.Unlock()
				reply(w, 429, "busy")
				return
			}
			token := randomToken()
			h.sessions[token] = now.Add(15 * time.Minute)
			h.mu.Unlock()
			http.SetCookie(w, &http.Cookie{Name: "openstick_setup", Value: token, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: 900})
			w.Header().Set("Content-Type", "application/json; charset=utf-8")
			_ = json.NewEncoder(w).Encode(map[string]string{"token": token, "address": h.host, "username": "openstick"})
			return
		default:
			http.NotFound(w, r)
			return
		}
		data, err := assets.ReadFile("web/" + file)
		if err != nil {
			reply(w, 500, "unavailable")
			return
		}
		w.Header().Set("Content-Type", contentType)
		_, _ = w.Write(data)
		return
	}
	if r.URL.Path != "/api/setup" || r.Method != "POST" {
		reply(w, 405, "method_not_allowed")
		return
	}
	if r.Header.Get("Origin") != "http://"+h.host {
		reply(w, 403, "forbidden")
		return
	}
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		reply(w, 415, "invalid_content_type")
		return
	}
	cookie, err := r.Cookie("openstick_setup")
	if err != nil {
		reply(w, 403, "session_expired")
		return
	}
	token := r.Header.Get("X-CSRF-Token")
	h.mu.Lock()
	expiry, exists := h.sessions[cookie.Value]
	valid := exists && time.Now().Before(expiry) && len(token) == 64 && subtle.ConstantTimeCompare([]byte(cookie.Value), []byte(token)) == 1
	if !valid {
		h.mu.Unlock()
		reply(w, 403, "session_expired")
		return
	}
	if time.Since(h.lastAttempt) < time.Second {
		h.mu.Unlock()
		reply(w, 429, "busy")
		return
	}
	h.lastAttempt = time.Now()
	h.mu.Unlock()
	input, err := decodeSetup(w, r)
	if err == nil {
		err = h.backend.apply(input.Password)
	}
	switch {
	case err == nil:
		reply(w, 200, "configured")
		h.done()
	case errors.Is(err, errConfigured):
		reply(w, 409, "configured")
	case errors.Is(err, errPassword):
		reply(w, 400, "invalid_password")
	default:
		reply(w, 503, "unavailable")
	}
}
