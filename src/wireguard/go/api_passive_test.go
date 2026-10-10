/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

import (
	"errors"
	"fmt"
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

func TestPassiveLifecycleUsesOriginalRegistry(t *testing.T) {
	handle := startPassiveTestDevice(t)
	passive, _ := lookupPassiveBackend(handle)
	if tunnelHandles[handle].Device != passive.Device {
		t.Fatal("passive device missing from original registry")
	}
	wgDisableSomeRoamingForBrokenMobileSemantics(handle)
	wgSendKeepalives(handle)
	wgTurnOffWithPassiveIO(handle)
	if _, ok := tunnelHandles[handle]; ok {
		t.Fatal("passive shutdown left original registry entry")
	}
	if _, err := passive.tun.Write([][]byte{{1}}, 0); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("passive TUN remains open: %v", err)
	}
	replacement := startPassiveTestDevice(t)
	if replacement == handle {
		t.Fatal("passive handle was reused")
	}
	wgTurnOffWithPassiveIO(handle)
	current, ok := lookupPassiveBackend(replacement)
	if !ok || tunnelHandles[replacement].Device != current.Device {
		t.Fatal("stale shutdown removed replacement")
	}
	if _, err := current.tun.Write([][]byte{{1}}, 0); err != nil {
		t.Fatal("stale shutdown closed replacement")
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

func TestPassiveEndpointRefreshPreservesPeer(t *testing.T) {
	handle := startPassiveTestDevice(t)
	backend, _ := lookupPassiveBackend(handle)
	var key device.NoisePublicKey
	key[0] = 1
	settings := fmt.Sprintf("public_key=%x\nendpoint=127.0.0.1:1234\nallowed_ip=10.0.0.1/32\n", key)
	if err := backend.IpcSet(settings); err != nil {
		t.Fatal(err)
	}
	peer := backend.LookupPeer(key)
	if peer == nil {
		t.Fatal("missing peer")
	}
	if err := peer.SendBuffers([][]byte{make([]byte, 123)}); err != nil {
		t.Fatal(err)
	}
	session := backend.bind.session
	if setPassiveEndpoints(handle, fmt.Sprintf("public_key=%x\nendpoint=127.0.0.1:5678\n", key)) != 0 {
		t.Fatal("refresh failed")
	}
	if backend.LookupPeer(key) != peer || backend.bind.session != session {
		t.Fatal("refresh replaced peer or bind")
	}

	config, err := backend.IpcGet()
	if err != nil || (!strings.Contains(config, "endpoint=127.0.0.1:5678") || !strings.Contains(config, "tx_bytes=123")) {
		t.Fatalf("endpoint not updated: %v, %s", err, config)
	}
	for _, invalid := range []string{"replace_peers=true\n", "listen_port=99\n", "private_key=00\n"} {
		if setPassiveEndpoints(handle, invalid) == 0 {
			t.Fatalf("accepted destructive update %q", invalid)
		}
	}
}

func TestPassiveRetryWritesOnlyUnsentSuffix(t *testing.T) {
	var offsets []int
	result := retryPassiveIO(3, false, nil, nil, func(offset int) passiveResult {
		offsets = append(offsets, offset)
		switch len(offsets) {
		case 1:
			return passiveResult{1, -3} // Backpressure after one packet.
		case 2:
			return passiveResult{0, -3} // Still blocked.
		default:
			return passiveResult{2, 0}
		}
	})
	if result.count != 3 || result.err() != nil || fmt.Sprint(offsets) != "[0 1 1]" {
		t.Fatalf("result=%+v offsets=%v", result, offsets)
	}
}

func TestPassiveRetryReadWaitsForPackets(t *testing.T) {
	calls := 0
	result := retryPassiveIO(16, true, nil, nil, func(offset int) passiveResult {
		if offset != 0 {
			t.Fatal("read reused a write offset")
		}
		calls++
		if calls == 1 {
			return passiveResult{0, -3}
		}
		return passiveResult{2, 0}
	})
	if result.count != 2 || result.err() != nil || calls != 2 {
		t.Fatalf("result=%+v calls=%d", result, calls)
	}
}

func TestPassiveRetryCancellation(t *testing.T) {
	for _, abort := range []bool{false, true} {
		t.Run(fmt.Sprint("abort=", abort), func(t *testing.T) {
			canceled := make(chan struct{})
			var done, aborted <-chan struct{}
			if abort {
				aborted = canceled
			} else {
				done = canceled
			}
			calls := 0
			result := retryPassiveIO(3, false, done, aborted, func(offset int) passiveResult {
				calls++
				close(canceled)
				return passiveResult{1, -3}
			})
			if result.count != 1 || !errors.Is(result.err(), net.ErrClosed) || calls != 1 {
				t.Fatalf("result=%+v calls=%d", result, calls)
			}
		})
	}
}

func TestPassiveRetryRejectsInvalidCompletion(t *testing.T) {
	result := retryPassiveIO(2, false, nil, nil, func(int) passiveResult {
		return passiveResult{3, -3}
	})
	if result.err() == nil {
		t.Fatal("accepted out-of-bounds completion")
	}
}
