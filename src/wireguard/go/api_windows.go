/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */

package main

import "C"

import (
	"fmt"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
	"unsafe"
)

func init() {
}

//export wgTurnOn
func wgTurnOn(settings *C.char, uuid *C.char, loggerFn unsafe.Pointer, profile *C.char) int32 {
	logger := newDeviceLogger(loggerFn, C.GoString(profile))
	uuidString := C.GoString(uuid)
	guidString := fmt.Sprintf("{%s}", uuidString)
	guid, err := windows.GUIDFromString(guidString)
	if err != nil {
		logger.Errorf("Unable to create GUID: %v", err)
		return -1
	}
	tun, err := tun.CreateTUNWithRequestedGUID(uuidString, &guid, 0)
	if err != nil {
		logger.Errorf("Unable to create new tun device from ifname: %v", err)
		return -1
	}
	logger.Verbosef("Attaching to interface")
	dev := device.NewDevice(tun, conn.NewStdNetBind(), logger)
	err = dev.IpcSet(C.GoString(settings))
	if err != nil {
		logger.Errorf("Unable to set IPC settings: %v", err)
		dev.Close()
		return -1
	}
	handle := wgTurnOnDevice(settings, dev, logger)
	if handle < 0 {
		dev.Close()
	}
	return handle
}
