/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

/*
#include "include/wg_go/passive_io.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"math"
	"net"
	"net/netip"
	"os"
	"runtime"
	"strconv"
	"sync"
	"unsafe"

	"golang.zx2c4.com/wireguard/device"
)

type passiveBackend struct {
	*device.Device
	bind *passiveBind
	tun  *passiveTun
}

// Passive handles belong to a separate registry and must only be passed to
// passive ABI functions. Never reuse IDs: late reads must not reach a new device.
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
	if settings == nil || tun == nil || tun.write == nil || tun.mtu == 0 || tun.mtu > passiveMaxDatagram {
		return -1
	}
	if link == nil || link.write == nil || link.local_port == 0 {
		return -1
	}
	linkWrite, tunWrite := link.write, tun.write
	bind := newPassiveBind(uint16(link.local_port), func(packets [][]byte, destination netip.AddrPort) error {
		var batch [passiveBatchSize]C.wg_packet
		var pins runtime.Pinner
		defer pins.Unpin()
		passiveOutputBatch(&batch, packets, 0, &pins)
		address := endpointToC(destination)
		status := C.wg_passive_link_write(linkWrite, context, &batch[0], C.uint32_t(len(packets)), &address)
		if status != 0 {
			return fmt.Errorf("host link write failed: %d", status)
		}
		return nil
	})
	passive := newPassiveTun(int(tun.mtu), func(packets [][]byte, offset int) error {
		var batch [passiveBatchSize]C.wg_packet
		var pins runtime.Pinner
		defer pins.Unpin()
		passiveOutputBatch(&batch, packets, offset, &pins)
		status := C.wg_passive_tun_write(tunWrite, context, &batch[0], C.uint32_t(len(packets)))
		if status != 0 {
			return fmt.Errorf("host TUN write failed: %d", status)
		}
		return nil
	})
	return turnOnPassiveDevice(C.GoString(settings), bind, passive)
}

// Pin payloads while C reads the Go descriptor array containing their pointers.
// The host copies them before returning; no payload copy is needed here.
func passiveOutputBatch(batch *[passiveBatchSize]C.wg_packet, packets [][]byte, offset int, pins *runtime.Pinner) {
	for i, packet := range packets {
		data := unsafe.SliceData(packet[offset:])
		if data != nil {
			pins.Pin(data)
		}
		batch[i] = C.wg_packet{data: (*C.uint8_t)(unsafe.Pointer(data)), size: C.uint32_t(len(packet) - offset)}
	}
}

func turnOnPassiveDevice(settings string, bind *passiveBind, tun *passiveTun) int32 {
	logger := &device.Logger{Verbosef: CLogger(0).Printf, Errorf: CLogger(1).Printf}
	dev := device.NewDevice(tun, bind, logger)
	if err := dev.IpcSet(settings); err != nil {
		logger.Errorf("Unable to set IPC settings: %v", err)
		dev.Close()
		return -1
	}
	if err := dev.Up(); err != nil {
		logger.Errorf("Unable to start device: %v", err)
		dev.Close()
		return -1
	}
	logger.Verbosef("Device started")

	passiveBackends.Lock()
	defer passiveBackends.Unlock()
	if passiveBackends.next > math.MaxInt32 {
		dev.Close()
		return -1
	}
	handle := int32(passiveBackends.next)
	passiveBackends.next++
	passiveBackends.byHandle[handle] = passiveBackend{dev, bind, tun}
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

//export wgDisableRoamingWithPassiveIO
func wgDisableRoamingWithPassiveIO(handle int32) {
	if tunnel, ok := lookupPassiveBackend(handle); ok {
		tunnel.DisableSomeRoamingForBrokenMobileSemantics()
	}
}

//export wgReceiveDatagrams
func wgReceiveDatagrams(handle C.int32_t, packets *C.wg_packet, sources *C.wg_endpoint, count C.uint32_t) C.int32_t {
	if count > C.WG_IO_MAX_BATCH || (count != 0 && (packets == nil || sources == nil)) {
		return C.WG_IO_INVALID
	}
	if count == 0 {
		return C.WG_IO_OK
	}
	batch := unsafe.Slice(packets, int(count))
	endpoints := unsafe.Slice(sources, int(count))
	var addresses [C.WG_IO_MAX_BATCH]netip.AddrPort
	for i, packet := range batch {
		if packet.size > passiveMaxDatagram || (packet.size != 0 && packet.data == nil) {
			return C.WG_IO_INVALID
		}
		address, err := endpointFromC(&endpoints[i])
		if err != nil {
			return C.WG_IO_INVALID
		}
		addresses[i] = address
	}
	backend, ok := lookupPassiveBackend(int32(handle))
	if !ok {
		return C.WG_IO_CLOSED
	}
	for i, packet := range batch {
		if err := backend.bind.enqueue(unsafe.Slice((*byte)(unsafe.Pointer(packet.data)), int(packet.size)), addresses[i]); err != nil {
			return passiveStatus(err)
		}
	}
	return C.WG_IO_OK
}

//export wgReceiveTunPackets
func wgReceiveTunPackets(handle C.int32_t, packets *C.wg_packet, count C.uint32_t) C.int32_t {
	if count > C.WG_IO_MAX_BATCH || (count != 0 && packets == nil) {
		return C.WG_IO_INVALID
	}
	if count == 0 {
		return C.WG_IO_OK
	}
	batch := unsafe.Slice(packets, int(count))
	for _, packet := range batch {
		if packet.size == 0 || packet.size > passiveMaxDatagram || packet.data == nil {
			return C.WG_IO_INVALID
		}
	}
	backend, ok := lookupPassiveBackend(int32(handle))
	if !ok {
		return C.WG_IO_CLOSED
	}
	for _, packet := range batch {
		if err := backend.tun.enqueue(unsafe.Slice((*byte)(unsafe.Pointer(packet.data)), int(packet.size))); err != nil {
			return passiveStatus(err)
		}
	}
	return C.WG_IO_OK
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

func passiveStatus(err error) C.int32_t {
	switch {
	case err == nil:
		return C.WG_IO_OK
	case errors.Is(err, net.ErrClosed), errors.Is(err, os.ErrClosed):
		return C.WG_IO_CLOSED
	case errors.Is(err, errPassiveQueueFull):
		return C.WG_IO_QUEUE_FULL
	default:
		return C.WG_IO_INVALID
	}
}
