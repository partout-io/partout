/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

import (
	"bytes"
	"errors"
	"fmt"
	"golang.org/x/crypto/curve25519"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/tuntest"
	"io"
	"net"
	"net/netip"
	"sync"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/conn"
)

func testBind() *passiveBind {
	return newPassiveBind(51820, func([]byte, netip.AddrPort) error { return nil })
}
func readOne(fn conn.ReceiveFunc) ([]byte, conn.Endpoint, error) {
	packets := [][]byte{make([]byte, passiveMaxDatagram)}
	sizes := make([]int, 1)
	endpoints := make([]conn.Endpoint, 1)
	_, err := fn(packets, sizes, endpoints)
	return packets[0][:sizes[0]], endpoints[0], err
}
func awaitError(t *testing.T, result <-chan error, want error) {
	t.Helper()
	select {
	case err := <-result:
		if !errors.Is(err, want) {
			t.Fatalf("got %v, want %v", err, want)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("operation blocked")
	}
}

func TestPassiveReceiveCopiesAndPreservesEndpoints(t *testing.T) {
	b := testBind()
	defer b.Close()
	fns, port, err := b.Open(0)
	if err != nil || port != 51820 || len(fns) != 1 {
		t.Fatalf("Open: %v %d %d", err, port, len(fns))
	}
	for _, text := range []string{"192.0.2.1:10", "[2001:db8::1]:20", "[fe80::1%42]:30", "[::ffff:192.0.2.1]:10"} {
		source := netip.MustParseAddrPort(text)
		for _, size := range []int{0, 4, passiveMaxDatagram} {
			data := bytes.Repeat([]byte{7}, size)
			if err := b.enqueue(data, source); err != nil {
				t.Fatal(err)
			}
			for i := range data {
				data[i] = 9
			}
			got, ep, err := readOne(fns[0])
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, bytes.Repeat([]byte{7}, size)) || ep.DstToString() != canonicalEndpoint(source).String() {
				t.Fatalf("packet/endpoint mismatch: %v", ep)
			}
		}
	}
}

func TestPassiveQueueBoundsAndShortBuffers(t *testing.T) {
	b := testBind()
	defer b.Close()
	fns, _, _ := b.Open(0)
	source := netip.MustParseAddrPort("127.0.0.1:1")
	for i := 0; i < passiveQueueSize; i++ {
		if err := b.enqueue([]byte{1, 2}, source); err != nil {
			t.Fatal(err)
		}
	}
	if err := b.enqueue(nil, source); !errors.Is(err, errPassiveQueueFull) {
		t.Fatal(err)
	}
	_, err := fns[0]([][]byte{make([]byte, 1)}, make([]int, 1), make([]conn.Endpoint, 1))
	if !errors.Is(err, io.ErrShortBuffer) {
		t.Fatal(err)
	}
	if err := b.enqueue(nil, source); err != nil {
		t.Fatal(err)
	}
	if err := b.enqueue(make([]byte, passiveMaxDatagram+1), source); !errors.Is(err, errPassivePacket) {
		t.Fatal(err)
	}
}

func TestPassiveCloseReopenAndPortPolicy(t *testing.T) {
	b := testBind()
	defer b.Close()
	if _, _, err := b.Open(99); !errors.Is(err, errPassivePort) {
		t.Fatal(err)
	}
	fns, _, _ := b.Open(51820)
	if _, _, err := b.Open(0); !errors.Is(err, conn.ErrBindAlreadyOpen) {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() { _, _, err := readOne(fns[0]); result <- err }()
	b.Close()
	awaitError(t, result, net.ErrClosed)
	if err := b.enqueue(nil, netip.MustParseAddrPort("127.0.0.1:1")); !errors.Is(err, net.ErrClosed) {
		t.Fatal(err)
	}
	fresh, _, err := b.Open(0)
	if err != nil {
		t.Fatal(err)
	}
	b.enqueue([]byte("new"), netip.MustParseAddrPort("127.0.0.1:1"))
	if _, _, err := readOne(fns[0]); !errors.Is(err, net.ErrClosed) {
		t.Fatal(err)
	}
	data, _, err := readOne(fresh[0])
	if err != nil || string(data) != "new" {
		t.Fatal(string(data), err)
	}
	b.enqueue([]byte("discard"), netip.MustParseAddrPort("127.0.0.1:1"))
	b.Close()
	b.Close()
	if b.SetMark(0) != nil || !errors.Is(b.SetMark(1), errPassiveMark) {
		t.Fatal("mark policy")
	}
	if _, _, err := newPassiveBind(0, nil).Open(0); !errors.Is(err, errPassivePort) {
		t.Fatal(err)
	}
}

func TestPassiveSendAndCloseWaitsForCallback(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	sentinel := errors.New("host send failed")
	b := newPassiveBind(51820, func(data []byte, ep netip.AddrPort) error {
		if string(data) != "udp" || ep.String() != "192.0.2.1:99" {
			return errPassivePacket
		}
		close(entered)
		<-release
		return sentinel
	})
	ep, _ := b.ParseEndpoint("[::ffff:192.0.2.1]:99")
	if !errors.Is(b.Send([][]byte{[]byte("udp")}, ep), net.ErrClosed) {
		t.Fatal("send before open")
	}
	b.Open(0)
	sent := make(chan error, 1)
	closed := make(chan error, 1)
	go func() { sent <- b.Send([][]byte{[]byte("udp")}, ep) }()
	<-entered
	go func() { closed <- b.Close() }()
	select {
	case <-closed:
		t.Fatal("Close returned during callback")
	case <-time.After(10 * time.Millisecond):
	}
	close(release)
	awaitError(t, sent, sentinel)
	awaitError(t, closed, nil)
}

func TestPassiveEndpointAndInvalidArguments(t *testing.T) {
	b := testBind()
	b.Open(0)
	defer b.Close()
	for _, text := range []string{"192.0.2.1:123", "[2001:db8::1]:9", "[fe80::1%42]:9"} {
		ep, err := b.ParseEndpoint(text)
		if err != nil {
			t.Fatal(err)
		}
		ep.ClearSrc()
		want, _ := netip.MustParseAddrPort(text).MarshalBinary()
		if !bytes.Equal(ep.DstToBytes(), want) || ep.SrcIP().IsValid() || ep.SrcToString() != "" {
			t.Fatal("endpoint mismatch")
		}
		native := endpointToC(ep.(*passiveEndpoint).addr)
		roundtrip, err := endpointFromC(&native)
		if err != nil || roundtrip.String() != text {
			t.Fatal(roundtrip, err)
		}
	}
	for _, text := range []string{"hostname:1", "127.0.0.1:65536", "::1:1"} {
		if _, err := b.ParseEndpoint(text); err == nil {
			t.Fatal(text)
		}
	}
	if !errors.Is(b.Send([][]byte{nil}, nil), conn.ErrWrongEndpointType) {
		t.Fatal("nil endpoint")
	}
	ep, _ := b.ParseEndpoint("127.0.0.1:1")
	if !errors.Is(b.Send([][]byte{nil, nil}, ep), errPassivePacket) {
		t.Fatal("oversize batch")
	}
	native := endpointToC(netip.MustParseAddrPort("127.0.0.1:1"))
	native.scope_id = 1
	if _, err := endpointFromC(&native); err == nil {
		t.Fatal("IPv4 scope accepted")
	}
	native.family = 0
	if _, err := endpointFromC(&native); err == nil {
		t.Fatal("invalid family accepted")
	}
	if wgReceiveDatagram(-1, nil, 0, nil) != -1 {
		t.Fatal("invalid endpoint status")
	}
	native = endpointToC(netip.MustParseAddrPort("127.0.0.1:1"))
	if wgReceiveDatagram(-1, nil, 0, &native) != -2 {
		t.Fatal("stale handle status")
	}
	if wgReceiveDatagram(-1, nil, 1, &native) != -1 {
		t.Fatal("null payload accepted")
	}
	if wgReceiveDatagram(-1, nil, 65536, &native) != -1 {
		t.Fatal("oversize payload accepted")
	}
}

func TestPassiveConcurrentLifecycle(t *testing.T) {
	b := testBind()
	defer b.Close()
	b.Open(0)
	source := netip.MustParseAddrPort("[::1]:9")
	ep, _ := b.ParseEndpoint(source.String())
	var workers sync.WaitGroup
	for i := 0; i < 4; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for j := 0; j < 300; j++ {
				b.enqueue([]byte{1}, source)
				b.Send([][]byte{{2}}, ep)
			}
		}()
	}
	for i := 0; i < 100; i++ {
		b.Close()
		b.Open(0)
	}
	workers.Wait()
}

func TestPassiveReceiveABI(t *testing.T) {
	b := testBind()
	tun := tuntest.NewChannelTUN()
	<-tun.TUN().Events() // Keep the device down; exercise the bind queue directly.
	dev := device.NewDevice(tun.TUN(), b, device.NewLogger(device.LogLevelSilent, ""))
	const handle = 2147483646
	passiveBackends.Lock()
	passiveBackends.byHandle[handle] = passiveBackend{Device: dev, bind: b}
	passiveBackends.Unlock()
	defer wgTurnOffWithPassiveIO(handle)
	fns, _, err := b.Open(0)
	if err != nil {
		t.Fatal(err)
	}
	source := endpointToC(netip.MustParseAddrPort("192.0.2.1:51820"))
	if status := wgReceiveDatagram(handle, &source.address[0], 4, &source); status != 0 {
		t.Fatal(status)
	}
	source.address[0] = 0
	got, ep, err := readOne(fns[0])
	if err != nil || !bytes.Equal(got, []byte{192, 0, 2, 1}) || ep.DstToString() != "192.0.2.1:51820" {
		t.Fatal(got, ep, err)
	}
	for i := 0; i < passiveQueueSize; i++ {
		if status := wgReceiveDatagram(handle, nil, 0, &source); status != 0 {
			t.Fatal(status)
		}
	}
	if status := wgReceiveDatagram(handle, nil, 0, &source); status != -3 {
		t.Fatal(status)
	}
	b.Close()
	if status := wgReceiveDatagram(handle, nil, 0, &source); status != -2 {
		t.Fatal(status)
	}
	wgTurnOffWithPassiveIO(handle)
	if status := wgReceiveDatagram(handle, nil, 0, &source); status != -2 {
		t.Fatal(status)
	}
}

func TestPassiveEncryptedRoundTrip(t *testing.T) {
	for _, family := range []string{"IPv4", "IPv6"} {
		t.Run(family, func(t *testing.T) {
			addresses := [2]netip.AddrPort{netip.MustParseAddrPort("192.0.2.1:10001"), netip.MustParseAddrPort("192.0.2.2:10002")}
			if family == "IPv6" {
				addresses = [2]netip.AddrPort{netip.MustParseAddrPort("[2001:db8::1]:10001"), netip.MustParseAddrPort("[2001:db8::2]:10002")}
			}
			var binds [2]*passiveBind
			for i := range binds {
				i := i
				binds[i] = newPassiveBind(addresses[i].Port(), func(packet []byte, dst netip.AddrPort) error {
					if dst != addresses[1-i] {
						return fmt.Errorf("wrong destination: %v", dst)
					}
					return binds[1-i].enqueue(packet, addresses[i])
				})
			}
			keys := [2][32]byte{{1, 1}, {2, 2}}
			var public [2][]byte
			for i := range keys {
				public[i], _ = curve25519.X25519(keys[i][:], curve25519.Basepoint)
			}
			receivedPackets := [2]chan []byte{make(chan []byte, 8), make(chan []byte, 8)}
			var tuns [2]*passiveTun
			for i := range tuns {
				i := i
				tuns[i] = newPassiveTun(1400, func(packet []byte) error {
					receivedPackets[i] <- append([]byte(nil), packet...)
					return nil
				})
			}
			var devices [2]*device.Device
			for i := range devices {
				devices[i] = device.NewDevice(tuns[i], binds[i], device.NewLogger(device.LogLevelSilent, ""))
				defer devices[i].Close()
				config := fmt.Sprintf("private_key=%x\npublic_key=%x\nendpoint=%s\nallowed_ip=10.0.0.%d/32\n", keys[i], public[1-i], addresses[1-i], 2-i)
				if err := devices[i].IpcSet(config); err != nil {
					t.Fatal(err)
				}
				if err := devices[i].Up(); err != nil {
					t.Fatal(err)
				}
			}
			for i := range devices {
				packet := tuntest.Ping(netip.MustParseAddr(fmt.Sprintf("10.0.0.%d", 2-i)), netip.MustParseAddr(fmt.Sprintf("10.0.0.%d", i+1)))
				if err := tuns[i].enqueue(packet); err != nil {
					t.Fatal(err)
				}
				select {
				case received := <-receivedPackets[1-i]:
					if !bytes.Equal(received, packet) {
						t.Fatal("decrypted packet mismatch")
					}
				case <-time.After(5 * time.Second):
					t.Fatal("handshake/data timeout")
				}
			}
		})
	}
}
