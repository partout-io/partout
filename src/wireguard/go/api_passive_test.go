/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

import (
	"errors"
	"net"
	"net/netip"
	"os"
	"strings"
	"sync"
	"testing"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

func startPassiveTestDevice(t *testing.T) int32 {
	t.Helper()
	handle := turnOnPassiveDevice("", testBind(), testTun())
	if handle < 0 {
		t.Fatal("passive startup failed")
	}
	t.Cleanup(func() { wgTurnOffWithPassiveIO(handle) })
	return handle
}

func TestPassiveLifecycleIsolatedFromLegacy(t *testing.T) {
	handle := startPassiveTestDevice(t)
	passive, _ := lookupPassiveBackend(handle)
	logger := device.NewLogger(device.LogLevelSilent, "")
	legacy := device.NewDevice(testTun(), testBind(), logger)
	// Deliberately overlap IDs to verify that each ABI uses its own registry.
	tunnelHandles[handle] = tunnelHandle{legacy, logger}
	t.Cleanup(func() { wgTurnOff(handle) })
	wgTurnOffWithPassiveIO(handle)
	if tunnelHandles[handle].Device != legacy {
		t.Fatal("passive shutdown changed the legacy registry")
	}
	if err := legacy.Up(); err != nil {
		t.Fatalf("passive shutdown closed the legacy device: %v", err)
	}
	if _, err := passive.tun.Write([][]byte{{1}}, 0); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("passive TUN remains open: %v", err)
	}

	replacement := startPassiveTestDevice(t)
	if replacement == handle {
		t.Fatal("passive handle was reused")
	}
	// Move the legacy entry to overlap the replacement, then stop only v1.
	delete(tunnelHandles, handle)
	tunnelHandles[replacement] = tunnelHandle{legacy, logger}
	t.Cleanup(func() { wgTurnOff(replacement) })
	wgTurnOff(replacement)
	wgTurnOffWithPassiveIO(handle) // A late shutdown cannot close the replacement.
	current, ok := lookupPassiveBackend(replacement)
	if !ok {
		t.Fatal("replacement missing")
	}
	if _, err := current.tun.Write([][]byte{{1}}, 0); err != nil {
		t.Fatal("legacy or stale shutdown closed the passive replacement")
	}
}

func TestPassiveRegistryConcurrentShutdown(t *testing.T) {
	handle := startPassiveTestDevice(t)
	var workers sync.WaitGroup
	for i := 0; i < 4; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for j := 0; j < 100; j++ {
				if tunnel, ok := lookupPassiveBackend(handle); ok {
					tunnel.tun.Write([][]byte{{1}}, 0)
				}
			}
		}()
	}
	wgTurnOffWithPassiveIO(handle)
	workers.Wait()
	if _, ok := lookupPassiveBackend(handle); ok {
		t.Fatal("closed passive device is still registered")
	}
}

func TestPassiveStartupFailureClosesIO(t *testing.T) {
	bind := testBind()
	tun := testTun()
	// The host bound 51820; a conflicting requested port must fail at Up.
	if handle := turnOnPassiveDevice("listen_port=1234\n", bind, tun); handle != -1 {
		wgTurnOffWithPassiveIO(handle)
		t.Fatal("startup accepted a conflicting listen port")
	}
	if _, err := tun.Write([][]byte{{1}}, 0); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("failed startup left TUN open: %v", err)
	}
}

func TestPassiveIdlePayloadBudget(t *testing.T) {
	// Observe the actual buffers allocated by WireGuard's two readers, rather
	// than only checking BatchSize. Readers remain blocked until cleanup.
	capacity := make(chan int, 2)
	read := func(bufs [][]byte, done <-chan struct{}) (int, error) {
		total := 0
		for _, buf := range bufs {
			total += cap(buf)
		}
		capacity <- total
		<-done
		return 0, net.ErrClosed
	}
	bind := newPassiveBind(51820,
		func(bufs [][]byte, _ []int, _ []conn.Endpoint, done <-chan struct{}) (int, error) {
			return read(bufs, done)
		},
		func([][]byte, netip.AddrPort) error { return nil })
	tun := newPassiveTun(1400,
		func(bufs [][]byte, _ []int, _ int, done <-chan struct{}) (int, error) { return read(bufs, done) },
		func(bufs [][]byte, _ int) (int, error) { return len(bufs), nil })
	handle := turnOnPassiveDevice("", bind, tun)
	if handle < 0 {
		t.Fatal("startup failed")
	}
	defer wgTurnOffWithPassiveIO(handle)
	budget := 2 << 20
	if total := <-capacity + <-capacity; total > budget {
		t.Fatalf("idle payload storage = %d bytes, budget = %d", total, budget)
	}
}
