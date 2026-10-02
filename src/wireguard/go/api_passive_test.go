/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

import (
	"errors"
	"os"
	"sync"
	"testing"

	"golang.zx2c4.com/wireguard/device"
)

func startPassiveTestDevice(t *testing.T) int32 {
	t.Helper()
	handle := turnOnPassiveDevice("", testBind(), newPassiveTun(1400, func([]byte) error { return nil }))
	if handle < 0 {
		t.Fatal("passive startup failed")
	}
	t.Cleanup(func() { wgTurnOffWithPassiveIO(handle) })
	return handle
}

func TestPassiveLifecycleIsolatedFromLegacy(t *testing.T) {
	handle := startPassiveTestDevice(t)
	passive, _ := lookupPassiveTunnel(handle)
	logger := device.NewLogger(device.LogLevelSilent, "")
	legacy := device.NewDevice(newPassiveTun(1400, func([]byte) error { return nil }), testBind(), logger)
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
	if err := passive.tun.enqueue([]byte{1}); !errors.Is(err, os.ErrClosed) {
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
	current, ok := lookupPassiveTunnel(replacement)
	if !ok || current.tun.enqueue([]byte{1}) != nil {
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
				if tunnel, ok := lookupPassiveTunnel(handle); ok {
					tunnel.tun.enqueue([]byte{1})
				}
			}
		}()
	}
	wgTurnOffWithPassiveIO(handle)
	workers.Wait()
	if _, ok := lookupPassiveTunnel(handle); ok {
		t.Fatal("closed passive device is still registered")
	}
}

func TestPassiveStartupFailureClosesIO(t *testing.T) {
	bind := testBind()
	tun := newPassiveTun(1400, func([]byte) error { return nil })
	// The host bound 51820; a conflicting requested port must fail at Up.
	if handle := turnOnPassiveDevice("listen_port=1234\n", bind, tun); handle != -1 {
		wgTurnOffWithPassiveIO(handle)
		t.Fatal("startup accepted a conflicting listen port")
	}
	if err := tun.enqueue([]byte{1}); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("failed startup left TUN open: %v", err)
	}
}
