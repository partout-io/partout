//go:build !windows

/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */

package main

// static void callLogger(void *func, void *ctx, int level, const char *msg);
import "C"

import (
	"os"
	"os/signal"
	"runtime"
	"unsafe"

	"golang.org/x/sys/unix"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
)

func init() {
	signals := make(chan os.Signal)
	signal.Notify(signals, unix.SIGUSR2)
	go func() {
		buf := make([]byte, os.Getpagesize())
		for {
			select {
			case <-signals:
				n := runtime.Stack(buf, true)
				buf[n] = 0
				loggerMutex.RLock()
				if uintptr(loggerFunc) != 0 {
					C.callLogger(loggerFunc, nil, 0, (*C.char)(unsafe.Pointer(&buf[0])))
				}
				loggerMutex.RUnlock()
			}
		}
	}()
}

//export wgTurnOn
func wgTurnOn(settings *C.char, tunFd int32) int32 {
	logger := &device.Logger{
		Verbosef: newCLogger(0).Printf,
		Errorf:   newCLogger(1).Printf,
	}
	dupTunFd, err := unix.Dup(int(tunFd))
	if err != nil {
		logger.Errorf("Unable to dup tun fd: %v", err)
		return -1
	}
	err = unix.SetNonblock(dupTunFd, true)
	if err != nil {
		logger.Errorf("Unable to set tun fd as non blocking: %v", err)
		unix.Close(dupTunFd)
		return -1
	}
	tun, err := wgCreateTun(dupTunFd)
	if err != nil {
		logger.Errorf("Unable to create new tun device from fd: %v", err)
		unix.Close(dupTunFd)
		return -1
	}
	logger.Verbosef("Attaching to interface")
	dev := device.NewDevice(tun, conn.NewStdNetBind(), logger)
	err = dev.IpcSet(C.GoString(settings))
	if err != nil {
		logger.Errorf("Unable to set IPC settings: %v", err)
		dev.Close()
		unix.Close(dupTunFd)
		return -1
	}
	handle := wgTurnOnDevice(settings, dev, logger)
	if handle == -1 {
		dev.Close()
		unix.Close(dupTunFd)
	}
	return handle
}
