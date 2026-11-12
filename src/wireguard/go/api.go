/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 */

package main

// #include <stdlib.h>
// #include <sys/types.h>
// static void callLogger(void *func, const char *profile, int level, const char *msg)
// {
// 	((void(*)(const char *, int, const char *))func)(profile, level, msg);
// }
import "C"

import (
	"fmt"
	"math"
	"runtime"
	"runtime/debug"
	"strings"
	"sync/atomic"
	"time"
	"unsafe"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

type tunnelHandle struct {
	*device.Device
	*device.Logger
}

var tunnelHandles = make(map[int32]tunnelHandle)

// Process-wide stack dumps have no profile context.
var signalLogger atomic.Pointer[CLogger]

func wgTurnOnDevice(settings *C.char, dev *device.Device, logger *device.Logger) int32 {
	err := dev.IpcSet(C.GoString(settings))
	if err != nil {
		logger.Errorf("Unable to set IPC settings: %v", err)
		return -1
	}

	dev.Up()
	logger.Verbosef("Device started")

	var i int32
	for i = 0; i < math.MaxInt32; i++ {
		if _, exists := tunnelHandles[i]; !exists {
			break
		}
	}
	if i == math.MaxInt32 {
		return -1
	}
	tunnelHandles[i] = tunnelHandle{dev, logger}
	return i
}

//export wgGetSocketV4
func wgGetSocketV4(tunnelHandle int32) int32 {
	dev, ok := tunnelHandles[tunnelHandle]
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
	dev, ok := tunnelHandles[tunnelHandle]
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
	dev, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return
	}
	delete(tunnelHandles, tunnelHandle)
	dev.Close()
}

//export wgSetConfig
func wgSetConfig(tunnelHandle int32, settings *C.char) int64 {
	dev, ok := tunnelHandles[tunnelHandle]
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
	device, ok := tunnelHandles[tunnelHandle]
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
	dev, ok := tunnelHandles[tunnelHandle]
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
	dev, ok := tunnelHandles[tunnelHandle]
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
	dev, ok := tunnelHandles[tunnelHandle]
	if !ok {
		return
	}
	dev.DisableSomeRoamingForBrokenMobileSemantics()
}

//export wgSendKeepalives
func wgSendKeepalives(handle int32) {
	if dev, ok := tunnelHandles[handle]; ok {
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

type CLogger struct {
	level    int
	function unsafe.Pointer
	profile  []byte
}

func newCLogger(level int, function unsafe.Pointer, profile string) CLogger {
	var owned []byte
	if profile != "" {
		owned = append([]byte(profile), 0)
	}
	return CLogger{level, function, owned}
}

func newDeviceLogger(function unsafe.Pointer, profile string) *device.Logger {
	signalLogger.Store(&CLogger{function: function})
	return &device.Logger{
		Verbosef: newCLogger(0, function, profile).Printf,
		Errorf:   newCLogger(1, function, profile).Printf,
	}
}

func (l CLogger) Printf(format string, args ...interface{}) {
	if uintptr(l.function) == 0 {
		return
	}
	gomsg := fmt.Sprintf(format, args...)
	cmsg := C.CString(gomsg)
	msg := (*C.char)(unsafe.Pointer(cmsg))
	var profile *C.char
	if len(l.profile) != 0 {
		profile = (*C.char)(unsafe.Pointer(&l.profile[0]))
	}
	C.callLogger(l.function, profile, C.int(l.level), msg)
	runtime.KeepAlive(l.profile)
	C.free(unsafe.Pointer(cmsg))
}

func main() {}
