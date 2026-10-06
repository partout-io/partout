/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

/*
#include "include/wg_go/passive_io.h"
*/
import "C"

import (
	"fmt"
	"math"
	"net"
	"net/netip"
	"runtime"
	"runtime/cgo"
	"strconv"
	"strings"
	"sync"
	"unsafe"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

type passiveBackend struct {
	*device.Device
	bind *passiveBind
	tun  *passiveTun
}

// Passive handles belong to a separate registry and must only be passed to
// passive ABI functions. Never reuse IDs: stale lifecycle calls must not reach a new device.
var passiveBackends = struct {
	sync.RWMutex
	next     int64
	byHandle map[int32]passiveBackend
}{byHandle: make(map[int32]passiveBackend)}

func lookupPassiveBackend(handle int32) (passiveBackend, bool) {
	passiveBackends.RLock()
	defer passiveBackends.RUnlock()
	tunnel, ok := passiveBackends.byHandle[handle]
	return tunnel, ok
}

//export wgTurnOnWithPassiveIO
func wgTurnOnWithPassiveIO(settings *C.char, link *C.wg_passive_link, tun *C.wg_passive_tun, context unsafe.Pointer) int32 {
	if settings == nil || tun == nil || tun.read == nil || tun.write == nil || tun.mtu == 0 || tun.mtu > passiveMaxDatagram {
		return -1
	}
	if link == nil || link.read == nil || link.write == nil || link.local_port == 0 {
		return -1
	}
	linkIO, tunIO := *link, *tun
	host := &passiveHost{ready: make(chan struct{}), aborted: make(chan struct{})}
	bind := newPassiveBind(uint16(linkIO.local_port),
		func(packets [][]byte, sizes []int, endpoints []conn.Endpoint, done <-chan struct{}) (int, error) {
			return host.read(linkIO.read, context, packets, sizes, endpoints, 0, done)
		},
		func(packets [][]byte, destination netip.AddrPort) error {
			address := endpointToC(destination)
			var pins runtime.Pinner
			pins.Pin(&address)
			defer pins.Unpin()
			_, err := host.write(packets, 0, func(batch *C.wg_packet, count C.uint32_t, request C.uintptr_t) C.int32_t {
				return C.wg_passive_link_write(linkIO.write, context, batch, count, &address, request)
			})
			return err
		})
	bind.host = host
	passive := newPassiveTun(int(tunIO.mtu),
		func(packets [][]byte, sizes []int, offset int, done <-chan struct{}) (int, error) {
			return host.read(tunIO.read, context, packets, sizes, nil, offset, done)
		},
		func(packets [][]byte, offset int) (int, error) {
			return host.write(packets, offset, func(batch *C.wg_packet, count C.uint32_t, request C.uintptr_t) C.int32_t {
				return C.wg_passive_tun_write(tunIO.write, context, batch, count, request)
			})
		})
	return turnOnPassiveDevice(C.GoString(settings), bind, passive)
}

func turnOnPassiveDevice(settings string, bind *passiveBind, tun *passiveTun) int32 {
	logger := &device.Logger{Verbosef: CLogger(0).Printf, Errorf: CLogger(1).Printf}
	dev := device.NewDevice(tun, bind, logger)
	closeDevice := func() {
		if bind.host != nil {
			close(bind.host.aborted)
		}
		dev.Close()
	}
	if err := dev.IpcSet(settings); err != nil {
		logger.Errorf("Unable to set IPC settings: %v", err)
		closeDevice()
		return -1
	}
	// Reserve a handle before Up can publish writes: no fallible registration
	// work may remain after the host has accepted borrowed requests.
	passiveBackends.Lock()
	if passiveBackends.next > math.MaxInt32 {
		passiveBackends.Unlock()
		closeDevice()
		return -1
	}
	handle := int32(passiveBackends.next)
	passiveBackends.next++
	passiveBackends.Unlock()
	if err := dev.Up(); err != nil {
		logger.Errorf("Unable to start device: %v", err)
		closeDevice()
		return -1
	}
	logger.Verbosef("Device started")
	passiveBackends.Lock()
	defer passiveBackends.Unlock()
	passiveBackends.byHandle[handle] = passiveBackend{dev, bind, tun}
	if bind.host != nil {
		close(bind.host.ready)
	}
	return handle
}

//export wgTurnOffWithPassiveIO
func wgTurnOffWithPassiveIO(handle int32) {
	passiveBackends.Lock()
	tunnel, ok := passiveBackends.byHandle[handle]
	delete(passiveBackends.byHandle, handle)
	passiveBackends.Unlock()
	if ok {
		tunnel.Close()
	}
}

//export wgGetConfigWithPassiveIO
func wgGetConfigWithPassiveIO(handle int32) *C.char {
	tunnel, ok := lookupPassiveBackend(handle)
	if !ok {
		return nil
	}
	settings, err := tunnel.IpcGet()
	if err != nil {
		return nil
	}
	return C.CString(settings)
}

//export wgSetEndpointsWithPassiveIO
func wgSetEndpointsWithPassiveIO(handle int32, settings *C.char) int64 {
	if settings == nil {
		return -1
	}
	return setPassiveEndpoints(handle, C.GoString(settings))
}

// Endpoint-only updates cannot reopen Bind or replace peers and their sessions.
// The caller runs this off its I/O queue: IpcSet can flush staged packets.
func setPassiveEndpoints(handle int32, settings string) int64 {
	tunnel, ok := lookupPassiveBackend(handle)
	if !ok {
		return -1
	}
	lines := strings.Split(settings, "\n")
	for i, line := range lines {
		switch {
		case line == "", strings.HasPrefix(line, "endpoint="):
		case strings.HasPrefix(line, "public_key="):
			// A stale endpoint update must not create a peer.
			lines[i] += "\nupdate_only=true"
		default:
			return -1
		}
	}
	if err := tunnel.IpcSet(strings.Join(lines, "\n")); err != nil {
		return -1
	}
	return 0
}

//export wgDisableRoamingWithPassiveIO
func wgDisableRoamingWithPassiveIO(handle int32) {
	if tunnel, ok := lookupPassiveBackend(handle); ok {
		tunnel.DisableSomeRoamingForBrokenMobileSemantics()
	}
}

func endpointFromC(endpoint *C.wg_endpoint) (netip.AddrPort, error) {
	if endpoint == nil {
		return netip.AddrPort{}, errPassivePacket
	}
	var address netip.Addr
	switch endpoint.family {
	case 4:
		if endpoint.scope_id != 0 {
			return netip.AddrPort{}, errPassivePacket
		}
		var bytes [4]byte
		for i := range bytes {
			bytes[i] = byte(endpoint.address[i])
		}
		address = netip.AddrFrom4(bytes)
	case 6:
		var bytes [16]byte
		for i := range bytes {
			bytes[i] = byte(endpoint.address[i])
		}
		address = netip.AddrFrom16(bytes)
		if endpoint.scope_id != 0 {
			if address.Is4In6() {
				return netip.AddrPort{}, errPassivePacket
			}
			address = address.WithZone(strconv.FormatUint(uint64(endpoint.scope_id), 10))
		}
	default:
		return netip.AddrPort{}, errPassivePacket
	}
	return canonicalEndpoint(netip.AddrPortFrom(address, uint16(endpoint.port))), nil
}

func endpointToC(address netip.AddrPort) C.wg_endpoint {
	address = canonicalEndpoint(address)
	endpoint := C.wg_endpoint{port: C.uint16_t(address.Port())}
	ip := address.Addr()
	if ip.Is4() {
		endpoint.family = 4
	} else {
		endpoint.family = 6
		scope, _ := strconv.ParseUint(ip.Zone(), 10, 32)
		endpoint.scope_id = C.uint32_t(scope)
	}
	for i, value := range ip.AsSlice() {
		endpoint.address[i] = C.uint8_t(value)
	}
	return endpoint
}

// An accepted request retains all pinned storage until the host completes it.
// The integer token crosses C; no Go object pointer is stored as a context.
type passiveResult struct {
	count  int
	status C.int32_t
}

func passiveRequest(submit func(C.uintptr_t) C.int32_t) passiveResult {
	done := make(chan passiveResult, 1)
	handle := cgo.NewHandle(done)
	defer handle.Delete()
	if status := submit(C.uintptr_t(handle)); status != 0 {
		return passiveResult{status: status}
	}
	return <-done
}

//export wgCompleteIO
func wgCompleteIO(request C.uintptr_t, count C.uint32_t, status C.int32_t) {
	cgo.Handle(request).Value().(chan passiveResult) <- passiveResult{int(count), status}
}

type passiveHost struct{ ready, aborted chan struct{} }

func (h *passiveHost) waitReady(done <-chan struct{}) bool {
	select {
	case <-done:
		return false
	case <-h.aborted:
		return false
	case <-h.ready:
		return true
	}
}
func (h *passiveHost) read(read C.wg_read_fn, context unsafe.Pointer, packets [][]byte,
	sizes []int, endpoints []conn.Endpoint, offset int, done <-chan struct{}) (int, error) {
	if !h.waitReady(done) {
		return 0, net.ErrClosed
	}
	var batch [passiveBatchSize]C.wg_read_packet
	var pins runtime.Pinner
	defer pins.Unpin()
	for i, packet := range packets {
		if len(packet) <= offset {
			return 0, errPassivePacket
		}
		data := unsafe.SliceData(packet[offset:])
		pins.Pin(data)
		batch[i] = C.wg_read_packet{data: (*C.uint8_t)(unsafe.Pointer(data)), capacity: C.uint32_t(len(packet) - offset)}
	}
	pins.Pin(&batch[0])
	result := passiveRequest(func(request C.uintptr_t) C.int32_t {
		return C.wg_passive_read(read, context, &batch[0], C.uint32_t(len(packets)), request)
	})
	if result.count < 0 || result.count > len(packets) {
		return 0, errPassivePacket
	}
	for i := 0; i < result.count; i++ {
		if batch[i].size > batch[i].capacity {
			return 0, errPassivePacket
		}
		sizes[i] = int(batch[i].size)
		if endpoints != nil {
			address, err := endpointFromC(&batch[i].source)
			if err != nil {
				return 0, err
			}
			endpoints[i] = &passiveEndpoint{addr: address}
		}
	}
	return result.count, result.err()
}

func (r passiveResult) err() error {
	switch r.status {
	case C.WG_IO_OK:
		return nil
	case C.WG_IO_CLOSED:
		return net.ErrClosed
	default:
		return fmt.Errorf("host I/O failed: %d", r.status)
	}
}

func (h *passiveHost) write(packets [][]byte, offset int,
	submit func(*C.wg_packet, C.uint32_t, C.uintptr_t) C.int32_t) (int, error) {
	// Up may synchronously send a keepalive handshake. The host must service
	// writes while startup runs; waiting for ready here would deadlock Up.
	var batch [passiveBatchSize]C.wg_packet
	var pins runtime.Pinner
	defer pins.Unpin()
	for i, packet := range packets {
		data := unsafe.SliceData(packet[offset:])
		if data != nil {
			pins.Pin(data)
		}
		batch[i] = C.wg_packet{data: (*C.uint8_t)(unsafe.Pointer(data)), size: C.uint32_t(len(packet) - offset)}
	}
	pins.Pin(&batch[0])
	result := passiveRequest(func(request C.uintptr_t) C.int32_t {
		return submit(&batch[0], C.uint32_t(len(packets)), request)
	})
	if result.count < 0 || result.count > len(packets) {
		return 0, errPassivePacket
	}
	if result.status == 0 && result.count != len(packets) {
		return result.count, errPassivePacket
	}
	return result.count, result.err()
}
