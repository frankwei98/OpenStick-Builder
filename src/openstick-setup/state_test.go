package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type fakeAccount struct {
	mu sync.Mutex

	password       bool
	passwordSetErr error
	setPasswordErr error
	syncErr        error
	openErr        error

	passwordSetCalls int
	setPasswordCalls int
	syncCalls        int
	openCalls        int
	passwords        []string
}

func (a *fakeAccount) passwordSet() (bool, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.passwordSetCalls++
	return a.password, a.passwordSetErr
}

func (a *fakeAccount) setPassword(password string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.setPasswordCalls++
	a.passwords = append(a.passwords, password)
	if a.setPasswordErr != nil {
		return a.setPasswordErr
	}
	a.password = true
	return nil
}

func (a *fakeAccount) syncAccount() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.syncCalls++
	return a.syncErr
}

func (a *fakeAccount) openLogin() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.openCalls++
	return a.openErr
}

func (a *fakeAccount) snapshot() fakeAccount {
	a.mu.Lock()
	defer a.mu.Unlock()
	return fakeAccount{
		password:         a.password,
		passwordSetCalls: a.passwordSetCalls,
		setPasswordCalls: a.setPasswordCalls,
		syncCalls:        a.syncCalls,
		openCalls:        a.openCalls,
		passwords:        append([]string(nil), a.passwords...),
	}
}

func writeStateFile(t *testing.T, dir, name string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(marker), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestValidatePasswordCountsUnicodeCodePointsAndRejectsControls(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		password string
		valid    bool
	}{
		{name: "twelve ASCII characters", password: "abcdefghijkl", valid: true},
		{name: "twelve non-ASCII characters", password: strings.Repeat("密", 12), valid: true},
		{name: "spaces in a passphrase", password: "correct horse battery staple", valid: true},
		{name: "eleven characters", password: strings.Repeat("a", 11)},
		{name: "one hundred twenty eight emoji", password: strings.Repeat("🙂", 128), valid: true},
		{name: "one hundred twenty nine characters", password: strings.Repeat("密", 129)},
		{name: "ASCII control", password: "abcdef\nghijkl"},
		{name: "Unicode control", password: "abcdef\u0085ghijkl"},
		{name: "invalid UTF-8", password: string([]byte("abcdefghijkl\xff"))},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validatePassword(test.password)
			if test.valid && err != nil {
				t.Fatalf("validatePassword() = %v, want valid", err)
			}
			if !test.valid && !errors.Is(err, errPassword) {
				t.Fatalf("validatePassword() = %v, want errPassword", err)
			}
		})
	}
}

func TestProvisionerAllowsOnlyOneConcurrentSetup(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	account := &fakeAccount{}
	p := &provisioner{dir: dir, account: account}
	const attempts = 12
	start := make(chan struct{})
	results := make(chan error, attempts)
	var workers sync.WaitGroup

	for i := 0; i < attempts; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			results <- p.apply("correct horse battery staple")
		}()
	}
	close(start)
	workers.Wait()
	close(results)

	succeeded, alreadyConfigured := 0, 0
	for err := range results {
		switch {
		case err == nil:
			succeeded++
		case errors.Is(err, errConfigured):
			alreadyConfigured++
		default:
			t.Fatalf("concurrent apply returned %v", err)
		}
	}
	if succeeded != 1 || alreadyConfigured != attempts-1 {
		t.Fatalf("got %d successes and %d configured results", succeeded, alreadyConfigured)
	}
	got := account.snapshot()
	if got.setPasswordCalls != 1 || got.syncCalls != 1 || got.openCalls != 1 {
		t.Fatalf("account mutation counts = set %d, sync %d, open %d; want 1 each", got.setPasswordCalls, got.syncCalls, got.openCalls)
	}
	if state, err := p.status(); err != nil || state != "configured" {
		t.Fatalf("status() = %q, %v; want configured", state, err)
	}
}

func TestProvisionerRecoversEveryDurablePowerLossState(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name           string
		prepare        func(*testing.T, string)
		passwordSet    bool
		wantState      string
		wantApplying   bool
		wantConfigured bool
		wantSync       int
		wantOpen       int
	}{
		{
			name: "before applying marker rename",
			prepare: func(t *testing.T, dir string) {
				writeStateFile(t, dir, ".applying-interrupted")
			},
			wantState: "unconfigured",
		},
		{
			name:      "after applying marker before password write",
			prepare:   func(t *testing.T, dir string) { writeStateFile(t, dir, "applying") },
			wantState: "unconfigured",
		},
		{
			name:        "after password write before account sync",
			prepare:     func(t *testing.T, dir string) { writeStateFile(t, dir, "applying") },
			passwordSet: true, wantState: "configured", wantConfigured: true,
			wantSync: 1, wantOpen: 1,
		},
		{
			name:        "after configured marker before login opens",
			prepare:     func(t *testing.T, dir string) { writeStateFile(t, dir, "configured") },
			passwordSet: true, wantState: "configured", wantConfigured: true,
			wantOpen: 1,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			test.prepare(t, dir)
			account := &fakeAccount{password: test.passwordSet}
			p := &provisioner{dir: dir, account: account}

			state, err := p.recover()
			if err != nil || state != test.wantState {
				t.Fatalf("recover() = %q, %v; want %q, nil", state, err, test.wantState)
			}
			_, applyingErr := os.Stat(filepath.Join(dir, "applying"))
			if got := applyingErr == nil; got != test.wantApplying {
				t.Fatalf("applying marker present = %v, want %v", got, test.wantApplying)
			}
			_, configuredErr := os.Stat(filepath.Join(dir, "configured"))
			if got := configuredErr == nil; got != test.wantConfigured {
				t.Fatalf("configured marker present = %v, want %v", got, test.wantConfigured)
			}
			got := account.snapshot()
			if got.syncCalls != test.wantSync || got.openCalls != test.wantOpen {
				t.Fatalf("account calls = sync %d, open %d; want %d, %d", got.syncCalls, got.openCalls, test.wantSync, test.wantOpen)
			}
		})
	}
}

func TestProvisionerRejectsExistingAccountWithoutOverwritingIt(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	account := &fakeAccount{password: true}
	p := &provisioner{dir: dir, account: account}

	if state, err := p.recover(); state != "" || !errors.Is(err, errUnavailable) {
		t.Fatalf("recover() = %q, %v; want unavailable", state, err)
	}
	if err := p.apply("first candidate password"); !errors.Is(err, errUnavailable) {
		t.Fatalf("apply() = %v, want unavailable", err)
	}
	got := account.snapshot()
	if got.setPasswordCalls != 0 || got.syncCalls != 0 || got.openCalls != 0 {
		t.Fatalf("existing account was mutated: set %d, sync %d, open %d", got.setPasswordCalls, got.syncCalls, got.openCalls)
	}
}

func TestProvisionerRejectsCorruptState(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		prepare func(*testing.T, string)
	}{
		{
			name: "both applying and configured",
			prepare: func(t *testing.T, dir string) {
				writeStateFile(t, dir, "applying")
				writeStateFile(t, dir, "configured")
			},
		},
		{
			name: "wrong contents",
			prepare: func(t *testing.T, dir string) {
				if err := os.WriteFile(filepath.Join(dir, "applying"), []byte("not a marker\n"), 0600); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "unsafe permissions",
			prepare: func(t *testing.T, dir string) {
				path := filepath.Join(dir, "configured")
				writeStateFile(t, dir, "configured")
				if err := os.Chmod(path, 0644); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "directory in place of marker",
			prepare: func(t *testing.T, dir string) {
				if err := os.Mkdir(filepath.Join(dir, "configured"), 0600); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "symbolic link in place of marker",
			prepare: func(t *testing.T, dir string) {
				writeStateFile(t, dir, "target")
				if err := os.Symlink(filepath.Join(dir, "target"), filepath.Join(dir, "configured")); err != nil {
					t.Fatal(err)
				}
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			test.prepare(t, dir)
			p := &provisioner{dir: dir, account: &fakeAccount{}}
			if state, err := p.status(); state != "" || err == nil {
				t.Fatalf("status() = %q, %v; want an error", state, err)
			}
		})
	}
}

func TestProvisionerDoesNotAcceptAnotherPasswordAfterUncertainWrite(t *testing.T) {
	t.Parallel()
	injected := errors.New("injected account failure")
	tests := []struct {
		name    string
		account *fakeAccount
	}{
		{name: "password write", account: &fakeAccount{setPasswordErr: injected}},
		{name: "password persistence", account: &fakeAccount{syncErr: injected}},
		{name: "opening login", account: &fakeAccount{openErr: injected}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			p := &provisioner{dir: t.TempDir(), account: test.account}
			if err := p.apply("first candidate password"); !errors.Is(err, errUnavailable) {
				t.Fatalf("first apply() = %v, want unavailable", err)
			}
			if err := p.apply("second candidate password"); !errors.Is(err, errUnavailable) {
				t.Fatalf("second apply() = %v, want unavailable", err)
			}
			got := test.account.snapshot()
			if got.setPasswordCalls != 1 {
				t.Fatalf("setPassword called %d times, want 1", got.setPasswordCalls)
			}
			if len(got.passwords) != 1 || got.passwords[0] != "first candidate password" {
				t.Fatalf("password write attempts = %q, want only first candidate", got.passwords)
			}
		})
	}
}

func TestShadowPasswordAcceptsOnlyFactoryLockOrCompleteSupportedHash(t *testing.T) {
	t.Parallel()
	entry := func(password string) string { return "openstick:" + password + ":1:2:3:4:5:6:7\n" }
	tests := []struct {
		name string
		data string
		set  bool
		ok   bool
	}{
		{name: "factory lock", data: entry("!"), ok: true},
		{name: "SHA-512", data: entry("$6$salt$hash"), set: true, ok: true},
		{name: "SHA-512 rounds", data: entry("$6$rounds=10000$salt$hash"), set: true, ok: true},
		{name: "yescrypt", data: entry("$y$j9T$salt$hash"), set: true, ok: true},
		{name: "missing account", data: "root:!:1:2:3:4:5:6:7\n"},
		{name: "duplicate account", data: entry("!") + entry("!")},
		{name: "empty password", data: entry("")},
		{name: "unknown lock", data: entry("*")},
		{name: "unknown hash", data: entry("$5$salt$hash")},
		{name: "incomplete hash", data: entry("$6$salt$")},
		{name: "malformed entry", data: "openstick:!\n"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			set, err := shadowPassword(test.data)
			if test.ok {
				if err != nil || set != test.set {
					t.Fatalf("shadowPassword() = %v, %v; want %v, nil", set, err, test.set)
				}
				return
			}
			if err == nil || set {
				t.Fatalf("shadowPassword() = %v, %v; want false and an error", set, err)
			}
		})
	}
}
