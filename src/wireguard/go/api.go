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
	passive *passiveBackend
}

// Both modes share non-reused handles so stale calls cannot reach a replacement.
var tunnelHandles = struct {
	sync.RWMutex
	next     int64
	byHandle map[int32]tunnelHandle
}{byHandle: make(map[int32]tunnelHandle)}

func reserveTunnelHandle() int32 {
	tunnelHandles.Lock()
	defer tunnelHandles.Unlock()
	if tunnelHandles.next > math.MaxInt32 {
		return -1
	}
	handle := int32(tunnelHandles.next)
	tunnelHandles.next++
	return handle
}

func registerTunnelHandle(handle int32, tunnel tunnelHandle) {
	tunnelHandles.Lock()
	defer tunnelHandles.Unlock()
	tunnelHandles.byHandle[handle] = tunnel
}

func lookupTunnelHandle(handle int32) (tunnelHandle, bool) {
	tunnelHandles.RLock()
	defer tunnelHandles.RUnlock()
	tunnel, ok := tunnelHandles.byHandle[handle]
	return tunnel, ok
}

//export wgSetLogger
func wgSetLogger(context, loggerFn uintptr) {
	loggerCtx = unsafe.Pointer(context)
	loggerFunc = unsafe.Pointer(loggerFn)
}

func wgTurnOnDevice(settings *C.char, dev *device.Device, logger *device.Logger) int32 {
	err := dev.IpcSet(C.GoString(settings))
	if err != nil {
		logger.Errorf("Unable to set IPC settings: %v", err)
		return -1
	}

	handle := reserveTunnelHandle()
	if handle < 0 {
		return -1
	}
	dev.Up()
	logger.Verbosef("Device started")
	registerTunnelHandle(handle, tunnelHandle{Device: dev, Logger: logger})
	return handle
}

//export wgGetSocketV4
func wgGetSocketV4(tunnelHandle int32) int32 {
	dev, ok := lookupTunnelHandle(tunnelHandle)
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
	dev, ok := lookupTunnelHandle(tunnelHandle)
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
func wgTurnOff(tunnelHandle int32) {
	tunnelHandles.Lock()
	dev, ok := tunnelHandles.byHandle[tunnelHandle]
	delete(tunnelHandles.byHandle, tunnelHandle)
	tunnelHandles.Unlock()
	if !ok {
		return
	}
	if dev.passive != nil && dev.passive.bind.host != nil {
		dev.passive.bind.host.abort()
	}
	dev.Close()
}

//export wgSetConfig
func wgSetConfig(tunnelHandle int32, settings *C.char) int64 {
	dev, ok := lookupTunnelHandle(tunnelHandle)
	if !ok {
		return 0
	}
	if settings == nil {
		return -1
	}
	if dev.passive != nil {
		return setPassiveEndpoints(tunnelHandle, C.GoString(settings))
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
	device, ok := lookupTunnelHandle(tunnelHandle)
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
	dev, ok := lookupTunnelHandle(tunnelHandle)
	if !ok || dev.passive != nil {
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
	dev, ok := lookupTunnelHandle(tunnelHandle)
	if !ok || dev.passive != nil {
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
	dev, ok := lookupTunnelHandle(tunnelHandle)
	if !ok {
		return
	}
	dev.DisableSomeRoamingForBrokenMobileSemantics()
}

//export wgSendKeepalives
func wgSendKeepalives(handle int32) {
	if dev, ok := lookupTunnelHandle(handle); ok {
		dev.SendKeepalivesToPeersWithCurrentKeypair()
	}
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
