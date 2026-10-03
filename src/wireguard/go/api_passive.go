/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

/*
#include "include/wg_go/passive_io.h"
static int32_t passiveWrite(wg_write_tun_fn write, void *context, const uint8_t *packet, uint32_t size) {
 return write(context, packet, size);
}
static int32_t passiveWriteLink(wg_write_link_fn write, void *context,
    const uint8_t *packet, uint32_t size, const wg_endpoint *destination) {
    return write(context, packet, size, destination);
}
*/
import "C"

import (
	"errors"
	"fmt"
	"math"
	"net"
	"net/netip"
	"os"
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
	bind, err := passiveBindFromC(link, context)
	if err != nil {
		return -1
	}
	write := tun.write
	passive := newPassiveTun(int(tun.mtu), func(packet []byte) error {
		status := C.passiveWrite(write, context, (*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(packet))), C.uint32_t(len(packet)))
		if status != 0 {
			return fmt.Errorf("host TUN write failed: %d", status)
		}
		return nil
	})
	return turnOnPassiveDevice(C.GoString(settings), bind, passive)
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

//export wgReceiveDatagram
func wgReceiveDatagram(handle C.int32_t, packet *C.uint8_t, size C.uint32_t, source *C.wg_endpoint) C.int32_t {
	if size > passiveMaxDatagram || (size != 0 && packet == nil) {
		return C.WG_IO_INVALID
	}
	address, err := endpointFromC(source)
	if err != nil {
		return C.WG_IO_INVALID
	}
	tunnel, ok := lookupPassiveBackend(int32(handle))
	if !ok {
		return C.WG_IO_CLOSED
	}
	return passiveStatus(tunnel.bind.enqueue(unsafe.Slice((*byte)(unsafe.Pointer(packet)), int(size)), address))
}

//export wgReceiveTunPacket
func wgReceiveTunPacket(handle C.int32_t, packet *C.uint8_t, size C.uint32_t) C.int32_t {
	if size == 0 || size > passiveMaxDatagram || packet == nil {
		return C.WG_IO_INVALID
	}
	tunnel, ok := lookupPassiveBackend(int32(handle))
	if !ok {
		return C.WG_IO_CLOSED
	}
	return passiveStatus(tunnel.tun.enqueue(unsafe.Slice((*byte)(unsafe.Pointer(packet)), int(size))))
}

func passiveBindFromC(callbacks *C.wg_passive_link, context unsafe.Pointer) (*passiveBind, error) {
	if callbacks == nil || callbacks.write == nil || callbacks.local_port == 0 {
		return nil, errPassivePacket
	}
	write := callbacks.write
	return newPassiveBind(uint16(callbacks.local_port), func(packet []byte, destination netip.AddrPort) error {
		address := endpointToC(destination)
		status := C.passiveWriteLink(write, context, (*C.uint8_t)(unsafe.Pointer(unsafe.SliceData(packet))), C.uint32_t(len(packet)), &address)
		if status != 0 {
			return fmt.Errorf("host link write failed: %d", status)
		}
		return nil
	}), nil
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
		bytes := ip.As4()
		for i, value := range bytes {
			endpoint.address[i] = C.uint8_t(value)
		}
	} else {
		endpoint.family = 6
		bytes := ip.As16()
		for i, value := range bytes {
			endpoint.address[i] = C.uint8_t(value)
		}
		scope, _ := strconv.ParseUint(ip.Zone(), 10, 32)
		endpoint.scope_id = C.uint32_t(scope)
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
