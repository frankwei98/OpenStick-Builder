package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

type systemAccount struct{}

func (systemAccount) passwordSet() (bool, error) {
	data, err := os.ReadFile("/etc/shadow")
	if err != nil {
		return false, err
	}
	return shadowPassword(string(data))
}

func (systemAccount) setPassword(password string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/sbin/chpasswd")
	cmd.Env = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C"}
	cmd.Stdin = strings.NewReader("openstick:" + password + "\n")
	// Never collect or log PAM output, which may contain sensitive input.
	return cmd.Run()
}

func (systemAccount) syncAccount() error {
	f, err := os.Open("/etc/shadow")
	if err != nil {
		return err
	}
	defer f.Close()
	if err = f.Sync(); err != nil {
		return err
	}
	return syncDir("/etc")
}

func (systemAccount) openLogin() error {
	data, err := os.ReadFile("/etc/nologin")
	if os.IsNotExist(err) {
		return syncDir("/etc")
	}
	if err != nil {
		return err
	}
	// Preserve an administrator's later maintenance lock.
	if string(data) != loginNotice {
		return nil
	}
	// Only recovery of the factory gate requires a committed password. After
	// setup, an administrator may intentionally lock or change the account.
	set, err := (systemAccount{}).passwordSet()
	if err != nil || !set {
		return errUnavailable
	}
	if err = os.Remove("/etc/nologin"); err != nil {
		return err
	}
	return syncDir("/etc")
}

func processLock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil // Held until process exit; never unlink the inode.
}

type peerListener struct {
	net.Listener
	uid uint32
}

func (l peerListener) Accept() (net.Conn, error) {
	for {
		conn, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		unix, ok := conn.(*net.UnixConn)
		if !ok {
			conn.Close()
			continue
		}
		raw, err := unix.SyscallConn()
		if err != nil {
			conn.Close()
			continue
		}
		allowed := false
		err = raw.Control(func(fd uintptr) {
			cred, e := syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
			allowed = e == nil && cred.Uid == l.uid
		})
		if err == nil && allowed {
			return conn, nil
		}
		conn.Close()
	}
}

func checkFactoryGate() error {
	data, err := os.ReadFile("/etc/nologin")
	if err != nil || string(data) != loginNotice {
		return errors.New("factory login gate missing")
	}
	return nil
}

func requireRoot() error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("helper requires root")
	}
	return nil
}
