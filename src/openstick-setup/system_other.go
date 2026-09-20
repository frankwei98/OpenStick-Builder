//go:build !linux

package main

import (
	"errors"
	"net"
	"os"
)

type systemAccount struct{}

func (systemAccount) passwordSet() (bool, error) { return false, errUnavailable }
func (systemAccount) setPassword(string) error   { return errUnavailable }
func (systemAccount) syncAccount() error         { return errUnavailable }
func (systemAccount) openLogin() error           { return errUnavailable }
func processLock(string) (*os.File, error)       { return nil, errUnavailable }

type peerListener struct {
	net.Listener
	uid uint32
}

func requireRoot() error      { return errors.New("helper only runs on Linux") }
func checkFactoryGate() error { return errUnavailable }
