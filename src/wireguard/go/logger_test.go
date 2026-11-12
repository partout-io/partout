/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

import (
	"testing"
	"unsafe"
)

func TestDeviceLoggerCapturesRegistration(t *testing.T) {
	first, second := 1, 2
	loggerMutex.Lock()
	previousContext := loggerCtx
	loggerCtx = unsafe.Pointer(&first)
	loggerMutex.Unlock()
	defer func() {
		loggerMutex.Lock()
		loggerCtx = previousContext
		loggerMutex.Unlock()
	}()
	firstLogger := newCLogger(0)
	loggerMutex.Lock()
	loggerCtx = unsafe.Pointer(&second)
	loggerMutex.Unlock()
	secondLogger := newCLogger(0)
	if firstLogger.context != unsafe.Pointer(&first) || secondLogger.context != unsafe.Pointer(&second) {
		t.Fatal("device logger did not retain its own registration")
	}
}
