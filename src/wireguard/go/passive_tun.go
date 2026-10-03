/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

import (
	"io"
	"os"
	"sync"

	"golang.zx2c4.com/wireguard/tun"
)

// passiveTun owns only packet queues. The host owns the interface and its MTU.
// Close joins writes, wakes reads and closes Events without closing a host fd.
type passiveTun struct {
	mu      sync.RWMutex
	closed  bool
	mtu     int
	write   func([]byte) error
	packets chan []byte
	done    chan struct{}
	events  chan tun.Event
}

var _ tun.Device = (*passiveTun)(nil)

func newPassiveTun(mtu int, write func([]byte) error) *passiveTun {
	return &passiveTun{mtu: mtu, write: write, packets: make(chan []byte, passiveQueueSize), done: make(chan struct{}), events: make(chan tun.Event)}
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
	for {
		select {
		case <-t.packets:
		default:
			return nil
		}
	}
}
func (t *passiveTun) enqueue(packet []byte) error {
	if len(packet) == 0 || len(packet) > passiveMaxDatagram {
		return errPassivePacket
	}
	t.mu.RLock()
	defer t.mu.RUnlock()
	if t.closed {
		return os.ErrClosed
	}
	select {
	case t.packets <- append([]byte(nil), packet...):
		return nil
	default:
		return errPassiveQueueFull
	}
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
	case packet := <-t.packets:
		t.mu.RLock()
		defer t.mu.RUnlock()
		if t.closed {
			return 0, os.ErrClosed
		}
		for i := 0; ; i++ {
			if len(bufs[i])-offset < len(packet) {
				return i, io.ErrShortBuffer
			}
			sizes[i] = copy(bufs[i][offset:], packet)
			if i+1 == len(bufs) {
				return i + 1, nil
			}
			select {
			case packet = <-t.packets:
			default:
				return i + 1, nil
			}
		}
	}
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
	for i, buf := range bufs {
		if err := t.write(buf[offset:]); err != nil {
			return i, err
		}
	}
	return len(bufs), nil
}
