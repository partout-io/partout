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
)

//export wgTurnOn
func wgTurnOn(settings *C.char, uuid *C.char) int32 {
	logger := &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
	}
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
	handle := wgTurnOnDevice(settings, dev, logger, nil)
	if handle < 0 {
		dev.Close()
	}
	return handle
}
