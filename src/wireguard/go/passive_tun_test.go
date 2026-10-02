/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"sync"
	"testing"
	"time"
)

func TestPassiveTunPacketsAndOffsets(t *testing.T) {
	var written []byte
	tun := newPassiveTun(1400, func(packet []byte) error { written = append([]byte(nil), packet...); return nil })
	defer tun.Close()
	if tun.File() != nil || tun.BatchSize() != 1 {
		t.Fatal("native TUN or batch")
	}
	if mtu, _ := tun.MTU(); mtu != 1400 {
		t.Fatal(mtu)
	}
	packet := []byte{0x45, 1, 2, 3}
	if err := tun.enqueue(packet); err != nil {
		t.Fatal(err)
	}
	packet[1] = 9
	buf := make([]byte, 10)
	sizes := []int{0}
	if n, err := tun.Read([][]byte{buf}, sizes, 3); n != 1 || err != nil || sizes[0] != 4 || !bytes.Equal(buf[3:7], []byte{0x45, 1, 2, 3}) {
		t.Fatal(n, err, sizes, buf)
	}
	if n, err := tun.Write([][]byte{buf[:7]}, 3); n != 1 || err != nil || !bytes.Equal(written, buf[3:7]) {
		t.Fatal(n, err, written)
	}
	if _, err := tun.Read([][]byte{buf}, sizes, -1); !errors.Is(err, errPassivePacket) {
		t.Fatal(err)
	}
	if _, err := tun.Write([][]byte{buf}, 11); !errors.Is(err, errPassivePacket) {
		t.Fatal(err)
	}
	tun.enqueue(packet)
	if _, err := tun.Read([][]byte{buf[:1]}, sizes, 0); !errors.Is(err, io.ErrShortBuffer) {
		t.Fatal(err)
	}
	for i := 0; i < passiveQueueSize; i++ {
		if err := tun.enqueue(packet); err != nil {
			t.Fatal(err)
		}
	}
	if err := tun.enqueue(packet); !errors.Is(err, errPassiveQueueFull) {
		t.Fatal(err)
	}
	tun.Close()
	if err := tun.enqueue(packet); !errors.Is(err, os.ErrClosed) {
		t.Fatal(err)
	}
	if _, err := tun.Read([][]byte{buf}, sizes, 0); !errors.Is(err, os.ErrClosed) {
		t.Fatal(err)
	}
	if _, err := tun.Write([][]byte{buf}, 0); !errors.Is(err, os.ErrClosed) {
		t.Fatal(err)
	}
	if _, open := <-tun.Events(); open {
		t.Fatal("events not closed")
	}
	if len(tun.packets) != 0 {
		t.Fatal("queued payloads retained")
	}
}

func TestPassiveTunCloseWakesReadAndJoinsWrite(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	tun := newPassiveTun(1400, func([]byte) error { close(entered); <-release; return nil })
	readDone := make(chan error, 1)
	go func() { _, err := tun.Read([][]byte{make([]byte, 100)}, []int{0}, 0); readDone <- err }()
	var writes sync.WaitGroup
	writes.Add(1)
	go func() { defer writes.Done(); tun.Write([][]byte{{0x45}}, 0) }()
	<-entered
	closed := make(chan struct{})
	go func() { tun.Close(); close(closed) }()
	select {
	case <-closed:
		t.Fatal("close did not join write")
	case <-time.After(10 * time.Millisecond):
	}
	close(release)
	writes.Wait()
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("close blocked")
	}
	select {
	case err := <-readDone:
		if !errors.Is(err, os.ErrClosed) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("read blocked")
	}
}
