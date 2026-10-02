/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 */

package main

// #include <stdlib.h>
// #include <sys/types.h>
// static void callLogger(void *func, void *ctx, int level, const char *msg)
// {
// 	((void(*)(void *, int, const char *))func)(ctx, level, msg);
// }
import "C"

import (
	"fmt"
	"math"
	"runtime/debug"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

var loggerFunc unsafe.Pointer
var loggerCtx unsafe.Pointer

type tunnelHandle struct {
	*device.Device
	*device.Logger
	passiveTun *passiveTun
}

var tunnelHandles = make(map[int32]tunnelHandle)
var tunnelHandlesMu sync.RWMutex

// Never reuse an ID: late host datagrams cannot enter a replacement device.
var nextTunnelHandle int64

func lookupTunnel(handle int32) (tunnelHandle, bool) {
	tunnelHandlesMu.RLock()
	defer tunnelHandlesMu.RUnlock()
	tunnel, ok := tunnelHandles[handle]
	return tunnel, ok
}

//export wgSetLogger
func wgSetLogger(context, loggerFn uintptr) {
	loggerCtx = unsafe.Pointer(context)
	loggerFunc = unsafe.Pointer(loggerFn)
}

func wgTurnOnDevice(settings *C.char, dev *device.Device, logger *device.Logger, passive *passiveTun) int32 {
	err := dev.IpcSet(C.GoString(settings))
	if err != nil {
		logger.Errorf("Unable to set IPC settings: %v", err)
		return -1
	}

	if err := dev.Up(); err != nil {
		logger.Errorf("Unable to start device: %v", err)
		return -1
	}
	logger.Verbosef("Device started")

	tunnelHandlesMu.Lock()
	defer tunnelHandlesMu.Unlock()
	if nextTunnelHandle > math.MaxInt32 {
		return -1
	}
	handle := int32(nextTunnelHandle)
	nextTunnelHandle++
	tunnelHandles[handle] = tunnelHandle{dev, logger, passive}
	return handle
}

//export wgGetSocketV4
func wgGetSocketV4(tunnelHandle int32) int32 {
	dev, ok := lookupTunnel(tunnelHandle)
	if !ok {
		return -1
	}
	bind, _ := dev.Bind().(conn.PeekLookAtSocketFd)
	if bind == nil {
		return -1
	}
	fd, err := bind.PeekLookAtSocketFd4()
	if err != nil {
		return -1
	}
	return int32(fd)
}

//export wgGetSocketV6
func wgGetSocketV6(tunnelHandle int32) int32 {
	dev, ok := lookupTunnel(tunnelHandle)
	if !ok {
		return -1
	}
	bind, _ := dev.Bind().(conn.PeekLookAtSocketFd)
	if bind == nil {
		return -1
	}
	fd, err := bind.PeekLookAtSocketFd6()
	if err != nil {
		return -1
	}
	return int32(fd)
}

//export wgTurnOff
func wgTurnOff(handle int32) {
	tunnelHandlesMu.Lock()
	dev, ok := tunnelHandles[handle]
	delete(tunnelHandles, handle)
	tunnelHandlesMu.Unlock()
	if ok {
		dev.Close()
	}
}

//export wgSetConfig
func wgSetConfig(tunnelHandle int32, settings *C.char) int64 {
	dev, ok := lookupTunnel(tunnelHandle)
	if !ok {
		return 0
	}
	err := dev.IpcSet(C.GoString(settings))
	if err != nil {
		dev.Errorf("Unable to set IPC settings: %v", err)
		if ipcErr, ok := err.(*device.IPCError); ok {
			return ipcErr.ErrorCode()
		}
		return -1
	}
	return 0
}

//export wgGetConfig
func wgGetConfig(tunnelHandle int32) *C.char {
	device, ok := lookupTunnel(tunnelHandle)
	if !ok {
		return nil
	}
	settings, err := device.IpcGet()
	if err != nil {
		return nil
	}
	return C.CString(settings)
}

//export wgBumpSockets
func wgBumpSockets(tunnelHandle int32) {
	dev, ok := lookupTunnel(tunnelHandle)
	if !ok {
		return
	}
	go func() {
		for i := 0; i < 10; i++ {
			err := dev.BindUpdate()
			if err == nil {
				dev.SendKeepalivesToPeersWithCurrentKeypair()
				return
			}
			dev.Errorf("Unable to update bind, try %d: %v", i+1, err)
			time.Sleep(time.Second / 2)
		}
		dev.Errorf("Gave up trying to update bind; tunnel is likely dysfunctional")
	}()
}

//export wgBumpSocketsAndWait
func wgBumpSocketsAndWait(tunnelHandle int32) {
	dev, ok := lookupTunnel(tunnelHandle)
	if !ok {
		return
	}
	for i := 0; i < 10; i++ {
		err := dev.BindUpdate()
		if err == nil {
			dev.SendKeepalivesToPeersWithCurrentKeypair()
			return
		}
		dev.Errorf("Unable to update bind, try %d: %v", i+1, err)
		time.Sleep(time.Second / 2)
	}
	dev.Errorf("Gave up trying to update bind; tunnel is likely dysfunctional")
}

//export wgDisableSomeRoamingForBrokenMobileSemantics
func wgDisableSomeRoamingForBrokenMobileSemantics(tunnelHandle int32) {
	dev, ok := lookupTunnel(tunnelHandle)
	if !ok {
		return
	}
	dev.DisableSomeRoamingForBrokenMobileSemantics()
}

//export wgVersion
func wgVersion() *C.char {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return C.CString("unknown")
	}
	for _, dep := range info.Deps {
		if dep.Path == "golang.zx2c4.com/wireguard" {
			parts := strings.Split(dep.Version, "-")
			if len(parts) == 3 && len(parts[2]) == 12 {
				return C.CString(parts[2][:7])
			}
			return C.CString(dep.Version)
		}
	}
	return C.CString("unknown")
}

type CLogger int

func (l CLogger) Printf(format string, args ...interface{}) {
	if uintptr(loggerFunc) == 0 {
		return
	}
	gomsg := fmt.Sprintf(format, args...)
	cmsg := C.CString(gomsg)
	msg := (*C.char)(unsafe.Pointer(cmsg))
	C.callLogger(loggerFunc, loggerCtx, C.int(l), msg)
	C.free(unsafe.Pointer(cmsg))
}

func main() {}
