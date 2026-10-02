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
				if uintptr(loggerFunc) != 0 {
					C.callLogger(loggerFunc, loggerCtx, 0, (*C.char)(unsafe.Pointer(&buf[0])))
				}
			}
		}
	}()
}

//export wgTurnOn
func wgTurnOn(settings *C.char, tunFd int32) int32 {
	return turnOnWithBind(settings, tunFd, conn.NewStdNetBind())
}

func turnOnWithBind(settings *C.char, tunFd int32, bind conn.Bind) int32 {
	logger := &device.Logger{
		Verbosef: CLogger(0).Printf,
		Errorf:   CLogger(1).Printf,
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
	dev := device.NewDevice(tun, bind, logger)
	handle := wgTurnOnDevice(settings, dev, logger, nil)
	if handle < 0 {
		dev.Close()
	}
	return handle
}
