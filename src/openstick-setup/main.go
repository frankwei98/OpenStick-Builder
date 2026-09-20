package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"os/user"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"
)

const stateDir = "/var/lib/openstick-setup"
const socketPath = "/run/openstick-setup/apply.sock"

type config struct {
	Address string `json:"address"`
	Peer    string `json:"peer"`
}

func readConfig() (config, error) {
	var cfg config
	data, err := os.ReadFile("/etc/openstick/setup.json")
	if err != nil {
		return cfg, err
	}
	if err = json.Unmarshal(data, &cfg); err != nil {
		return cfg, err
	}
	ip := net.ParseIP(cfg.Address)
	peer := net.ParseIP(cfg.Peer)
	if ip == nil || ip.To4() == nil || ip.IsUnspecified() || ip.IsLoopback() || peer == nil || peer.To4() == nil || ip.Equal(peer) {
		return cfg, errors.New("invalid USB addresses")
	}
	return cfg, nil
}

func runServer(listener net.Listener, handler func(func()) http.Handler, delay time.Duration) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	server := &http.Server{ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 5 * time.Second, MaxHeaderBytes: 4096, ErrorLog: log.New(io.Discard, "", 0)}
	var once sync.Once
	done := func() { once.Do(func() { time.AfterFunc(delay, stop) }) }
	server.Handler = handler(done)
	finished := make(chan struct{})
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
		close(finished)
	}()
	err := server.Serve(listener)
	stop()
	<-finished
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

// Bound admitted connections before net/http creates a goroutine for each one.
// The OS backlog handles additional connections; deadlines free occupied slots.
type boundedListener struct {
	net.Listener
	slots chan struct{}
}
type boundedConn struct {
	net.Conn
	release func()
	once    sync.Once
}

func (c *boundedConn) Close() error { err := c.Conn.Close(); c.once.Do(c.release); return err }
func (l boundedListener) Accept() (net.Conn, error) {
	l.slots <- struct{}{}
	conn, err := l.Listener.Accept()
	if err != nil {
		<-l.slots
		return nil, err
	}
	return &boundedConn{Conn: conn, release: func() { <-l.slots }}, nil
}

func run() error {
	if len(os.Args) != 2 {
		return errors.New("usage: openstick-setup serve|apply")
	}
	switch os.Args[1] {
	case "apply":
		if err := requireRoot(); err != nil {
			return err
		}
		if err := ensurePrivateDir(stateDir); err != nil {
			return err
		}
		lock, err := processLock(filepath.Join(stateDir, "lock"))
		if err != nil {
			return errors.New("another helper is running")
		}
		defer lock.Close()
		p := &provisioner{dir: stateDir, account: systemAccount{}}
		state, err := p.status()
		if err != nil {
			return err
		}
		if state != "configured" {
			if err = checkFactoryGate(); err != nil {
				return err
			}
		}
		state, err = p.recover()
		if err != nil {
			return errors.New("setup recovery failed; access remains closed")
		}
		if state == "configured" {
			return nil
		}
		account, err := user.Lookup("openstick-setup")
		if err != nil {
			return err
		}
		uid, err := strconv.ParseUint(account.Uid, 10, 32)
		if err != nil {
			return err
		}
		// systemd owns this root-writable RuntimeDirectory; stale sockets are safe to remove.
		if err = os.Remove(socketPath); err != nil && !os.IsNotExist(err) {
			return err
		}
		listener, err := net.Listen("unix", socketPath)
		if err != nil {
			return err
		}
		defer listener.Close()
		if err = os.Chmod(socketPath, 0660); err != nil {
			return err
		}
		limited := boundedListener{peerListener{listener, uint32(uid)}, make(chan struct{}, 4)}
		return runServer(limited, func(done func()) http.Handler { return helperHandler(p, done) }, 5*time.Second)
	case "serve":
		if os.Geteuid() == 0 {
			return errors.New("HTTP service must run as an unprivileged user")
		}
		cfg, err := readConfig()
		if err != nil {
			return err
		}
		backend := newHelperClient(socketPath)
		// Requires/After order process startup, not socket readiness.
		for attempt := 0; attempt < 20; attempt++ {
			err = backend.ready()
			if err == nil {
				break
			}
			if errors.Is(err, errConfigured) {
				return nil
			}
			time.Sleep(250 * time.Millisecond)
		}
		if err != nil {
			return errUnavailable
		}
		address := net.JoinHostPort(cfg.Address, "8080")
		listener, err := net.Listen("tcp4", address)
		if err != nil {
			return err
		} // Never fall back to a wildcard address.
		defer listener.Close()
		return runServer(boundedListener{listener, make(chan struct{}, 16)}, func(done func()) http.Handler {
			return &webHandler{host: address, peer: cfg.Peer, backend: backend, done: done, sessions: make(map[string]time.Time)}
		}, time.Second)
	default:
		return errors.New("unknown mode")
	}
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
