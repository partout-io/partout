/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

import "C"

import (
	"math"
	"sync"

	"golang.zx2c4.com/wireguard/device"
)

type passiveTunnel struct {
	*device.Device
	bind *passiveBind
	tun  *passiveTun
}

// Passive handles belong to a separate registry and must only be passed to
// passive ABI functions. Never reuse IDs: late reads must not reach a new device.
var passiveTunnels = struct {
	sync.RWMutex
	next     int64
	byHandle map[int32]passiveTunnel
}{byHandle: make(map[int32]passiveTunnel)}

func lookupPassiveTunnel(handle int32) (passiveTunnel, bool) {
	passiveTunnels.RLock()
	defer passiveTunnels.RUnlock()
	tunnel, ok := passiveTunnels.byHandle[handle]
	return tunnel, ok
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

	passiveTunnels.Lock()
	defer passiveTunnels.Unlock()
	if passiveTunnels.next > math.MaxInt32 {
		dev.Close()
		return -1
	}
	handle := int32(passiveTunnels.next)
	passiveTunnels.next++
	passiveTunnels.byHandle[handle] = passiveTunnel{dev, bind, tun}
	return handle
}

//export wgTurnOffWithPassiveIO
func wgTurnOffWithPassiveIO(handle int32) {
	passiveTunnels.Lock()
	tunnel, ok := passiveTunnels.byHandle[handle]
	delete(passiveTunnels.byHandle, handle)
	passiveTunnels.Unlock()
	if ok {
		tunnel.Close()
	}
}

//export wgGetConfigWithPassiveIO
func wgGetConfigWithPassiveIO(handle int32) *C.char {
	tunnel, ok := lookupPassiveTunnel(handle)
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
	if tunnel, ok := lookupPassiveTunnel(handle); ok {
		tunnel.DisableSomeRoamingForBrokenMobileSemantics()
	}
}
