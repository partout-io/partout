/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

import (
	"os"
	"sync"

	"golang.zx2c4.com/wireguard/tun"
)

// passiveTun lends WireGuard buffers to the host, which owns all native I/O.
// Close joins writes, wakes reads and closes Events without closing a host fd.
type passiveTun struct {
	read   func([][]byte, []int, int, <-chan struct{}) (int, error)
	mu     sync.RWMutex
	closed bool
	mtu    int
	write  func([][]byte, int) (int, error)
	done   chan struct{}
	events chan tun.Event
}

var _ tun.Device = (*passiveTun)(nil)

func newPassiveTun(mtu int, read func([][]byte, []int, int, <-chan struct{}) (int, error), write func([][]byte, int) (int, error)) *passiveTun {
	return &passiveTun{mtu: mtu, read: read, write: write, done: make(chan struct{}), events: make(chan tun.Event)}
}
func (*passiveTun) File() *os.File             { return nil }
func (*passiveTun) Name() (string, error)      { return "host", nil }
func (t *passiveTun) MTU() (int, error)        { return t.mtu, nil }
func (*passiveTun) BatchSize() int             { return passiveBatchSize }
func (t *passiveTun) Events() <-chan tun.Event { return t.events }
func (t *passiveTun) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return nil
	}
	t.closed = true
	close(t.done)
	close(t.events)
	return nil
}
func (t *passiveTun) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	if len(bufs) == 0 || len(bufs) > passiveBatchSize || len(sizes) < len(bufs) || offset < 0 {
		return 0, errPassivePacket
	}
	for _, buf := range bufs {
		if offset > len(buf) {
			return 0, errPassivePacket
		}
	}
	select {
	case <-t.done:
		return 0, os.ErrClosed
	default:
	}
	return t.read(bufs, sizes, offset, t.done)
}
func (t *passiveTun) Write(bufs [][]byte, offset int) (int, error) {
	if len(bufs) == 0 || len(bufs) > passiveBatchSize || offset < 0 {
		return 0, errPassivePacket
	}
	for _, buf := range bufs {
		if offset >= len(buf) || len(buf)-offset > passiveMaxDatagram {
			return 0, errPassivePacket
		}
	}
	t.mu.RLock()
	defer t.mu.RUnlock()
	if t.closed {
		return 0, os.ErrClosed
	}
	return t.write(bufs, offset)
}
