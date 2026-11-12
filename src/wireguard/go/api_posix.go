//go:build !windows

/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */

package main

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
				if logger := signalLogger.Load(); logger != nil {
					logger.Printf("%s", buf[:n])
				}
			}
		}
	}()
}

//export wgTurnOn
func wgTurnOn(settings *C.char, tunFd int32, loggerFn unsafe.Pointer, profile *C.char) int32 {
	logger := newDeviceLogger(loggerFn, C.GoString(profile))
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
