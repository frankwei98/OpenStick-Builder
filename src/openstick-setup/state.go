package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

const marker = "openstick-setup-v1\n"
const loginNotice = "Complete OpenStick setup over USB before logging in.\n"

var errConfigured = errors.New("already configured")
var errUnavailable = errors.New("setup unavailable")
var errPassword = errors.New("invalid password")

type accountStore interface {
	passwordSet() (bool, error)
	setPassword(string) error
	syncAccount() error
	openLogin() error
}

type provisioner struct {
	mu      sync.Mutex
	dir     string
	account accountStore
	failed  bool // An uncertain write is never retried by this process.
}

func validatePassword(password string) error {
	n := utf8.RuneCountInString(password)
	if !utf8.ValidString(password) || n < 12 || n > 128 {
		return errPassword
	}
	for _, r := range password {
		if unicode.IsControl(r) {
			return errPassword
		}
	}
	return nil
}

func syncDir(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

func (p *provisioner) has(name string) (bool, error) {
	path := filepath.Join(p.dir, name)
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		return false, errUnavailable
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	if string(data) != marker {
		return false, errUnavailable
	}
	return true, nil
}

func (p *provisioner) status() (string, error) {
	configured, err := p.has("configured")
	if err != nil {
		return "", err
	}
	applying, err := p.has("applying")
	if err != nil || (configured && applying) {
		return "", errUnavailable
	}
	if configured {
		return "configured", nil
	}
	if applying {
		return "applying", nil
	}
	return "unconfigured", nil
}

// recover runs before opening the helper socket, under the lifetime process lock.
// The shadow entry is the commit evidence: it starts as exactly "!" in the image.
func (p *provisioner) recover() (string, error) {
	state, err := p.status()
	if err != nil {
		return "", err
	}
	if state == "configured" {
		return state, p.account.openLogin()
	}
	set, err := p.account.passwordSet()
	if err != nil {
		return "", err
	}
	if state == "unconfigured" {
		if set {
			return "", errUnavailable
		} // Never claim an existing account.
		return state, nil
	}
	if set {
		if err = p.finish(); err != nil {
			return "", err
		}
		return "configured", nil
	}
	if err = os.Remove(filepath.Join(p.dir, "applying")); err != nil {
		return "", err
	}
	if err = syncDir(p.dir); err != nil {
		return "", err
	}
	return "unconfigured", nil
}

func (p *provisioner) begin() error {
	// A crash while staging leaves an ignored temp file; the account is untouched.
	tmp, err := os.CreateTemp(p.dir, ".applying-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err = tmp.WriteString(marker); err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(tmp.Name(), filepath.Join(p.dir, "applying")); err != nil {
		return err
	}
	return syncDir(p.dir)
}

func (p *provisioner) finish() error {
	if err := p.account.syncAccount(); err != nil {
		return err
	}
	if err := os.Rename(filepath.Join(p.dir, "applying"), filepath.Join(p.dir, "configured")); err != nil {
		return err
	}
	if err := syncDir(p.dir); err != nil {
		return err
	}
	return p.account.openLogin()
}

func (p *provisioner) apply(password string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.failed {
		return errUnavailable
	}
	state, err := p.status()
	if err != nil {
		return errUnavailable
	}
	if state == "configured" {
		return errConfigured
	}
	if state != "unconfigured" {
		return errUnavailable
	}
	if err = validatePassword(password); err != nil {
		return err
	}
	set, err := p.account.passwordSet()
	if err != nil || set {
		return errUnavailable
	}
	// From here, any failure requires recovery, never another password submission.
	p.failed = true
	if err = p.begin(); err != nil {
		return errUnavailable
	}
	if err = p.account.setPassword(password); err != nil {
		return errUnavailable
	}
	set, err = p.account.passwordSet()
	if err != nil || !set {
		return errUnavailable
	}
	if err = p.finish(); err != nil {
		return errUnavailable
	}
	p.failed = false
	return nil
}

// Only the factory lock and a complete supported crypt hash are acceptable during
// recovery. Empty, locked hashes and unknown formats fail closed.
func shadowPassword(data string) (bool, error) {
	count := 0
	value := ""
	for _, line := range strings.Split(data, "\n") {
		fields := strings.Split(line, ":")
		if len(fields) > 0 && fields[0] == "openstick" {
			if len(fields) != 9 {
				return false, errUnavailable
			}
			count++
			value = fields[1]
		}
	}
	if count != 1 {
		return false, errUnavailable
	}
	if value == "!" {
		return false, nil
	}
	fields := strings.Split(value, "$")
	if len(fields) != 5 && len(fields) != 4 {
		return false, errUnavailable
	}
	if fields[0] != "" {
		return false, errUnavailable
	}
	switch fields[1] {
	case "y":
		if len(fields) != 5 {
			return false, errUnavailable
		}
	case "6":
		if len(fields) == 5 && !strings.HasPrefix(fields[2], "rounds=") {
			return false, errUnavailable
		}
	default:
		return false, errUnavailable
	}
	for _, field := range fields[2:] {
		if field == "" {
			return false, errUnavailable
		}
	}
	return true, nil
}

func ensurePrivateDir(path string) error {
	if err := os.MkdirAll(path, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode().Perm() != 0700 {
		return fmt.Errorf("unsafe state directory")
	}
	return syncDir(filepath.Dir(path))
}
