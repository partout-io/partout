/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"testing"
	"time"
)

func TestPassiveTunBatches(t *testing.T) {
	var written [][]byte
	calls := 0
	failAfter := passiveBatchSize + 1
	sentinel := errors.New("host write failed")
	tun := newPassiveTun(1400, func(packets [][]byte, offset int) error {
		calls++
		if len(packets) > failAfter {
			return sentinel
		}
		for _, packet := range packets {
			written = append(written, append([]byte(nil), packet[offset:]...))
		}
		return nil
	})
	defer tun.Close()
	if tun.BatchSize() != 256 {
		t.Fatal(tun.BatchSize())
	}
	bufs := make([][]byte, tun.BatchSize())
	sizes := make([]int, len(bufs))
	for i := range bufs {
		bufs[i] = make([]byte, 4)
		if err := tun.enqueue([]byte{0x45, byte(i)}); err != nil {
			t.Fatal(err)
		}
	}
	if n, err := tun.Read(bufs, sizes, 2); n != len(bufs) || err != nil {
		t.Fatal(n, err)
	}
	for i, buf := range bufs {
		if sizes[i] != 2 || !bytes.Equal(buf, []byte{0, 0, 0x45, byte(i)}) {
			t.Fatal("batch order or offset lost", i, buf)
		}
	}
	if n, err := tun.Write(bufs, 2); n != len(bufs) || err != nil || len(written) != len(bufs) || calls != 1 {
		t.Fatal("full write batch", n, err)
	}
	for i, packet := range written {
		if !bytes.Equal(packet, []byte{0x45, byte(i)}) {
			t.Fatal("write order or offset lost", i, packet)
		}
	}
	written, failAfter = nil, 2
	tun.enqueue([]byte{0x45})
	done := make(chan error, 1)
	go func() {
		n, err := tun.Read(bufs, sizes, 2)
		if err == nil && (n != 1 || sizes[0] != 1) {
			err = fmt.Errorf("sparse batch: %d %v", n, sizes)
		}
		done <- err
	}()
	awaitError(t, done, nil)
	if n, err := tun.Write(bufs[:4], 2); n != 0 || !errors.Is(err, sentinel) || len(written) != 0 || calls != 2 {
		t.Fatal("failed write accepted a prefix", n, written, err)
	}
	written = nil
	if n, err := tun.Write([][]byte{{0, 0, 0x45}, {0}}, 2); n != 0 || !errors.Is(err, errPassivePacket) || len(written) != 0 || calls != 2 {
		t.Fatal("invalid batch wrote a prefix", n, err)
	}
	tun.enqueue([]byte{0x45})
	tun.enqueue([]byte{0x45, 1, 2})
	if n, err := tun.Read([][]byte{make([]byte, 3), make([]byte, 3)}, make([]int, 2), 1); n != 1 || !errors.Is(err, io.ErrShortBuffer) {
		t.Fatal("short-buffer prefix", n, err)
	}
	if _, err := tun.Read(bufs, sizes[:1], 0); !errors.Is(err, errPassivePacket) {
		t.Fatal("short sizes accepted", err)
	}
}

func TestPassiveTunPacketsAndOffsets(t *testing.T) {
	var written []byte
	tun := newPassiveTun(1400, func(packets [][]byte, offset int) error {
		written = append([]byte(nil), packets[0][offset:]...)
		return nil
	})
	defer tun.Close()
	if tun.File() != nil || tun.BatchSize() != passiveBatchSize {
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
	tun := newPassiveTun(1400, func([][]byte, int) error { close(entered); <-release; return nil })
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

func TestPassiveTunWritePreservesCompletedPrefix(t *testing.T) {
	tun := newPassiveTun(1400, func([][]byte, int) error {
		return &passiveWriteError{count: 1, err: os.ErrClosed}
	})
	defer tun.Close()
	n, err := tun.Write([][]byte{{0x45}, {0x60}}, 0)
	if n != 1 || !errors.Is(err, os.ErrClosed) {
		t.Fatalf("partially cancelled write = %d, %v; want 1, closed", n, err)
	}
}
