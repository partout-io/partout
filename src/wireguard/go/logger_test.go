/* SPDX-License-Identifier: MIT
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */
package main

import (
	"sync"
	"testing"
)

func TestDeviceLoggerOwnsProfile(t *testing.T) {
	var workers sync.WaitGroup
	for _, profile := range []string{"11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"} {
		workers.Add(1)
		go func(profile string) {
			defer workers.Done()
			source := []byte(profile)
			logger := CLogger{profile: append([]byte(string(source)), 0)}
			source[0] = 'X'
			if string(logger.profile) != profile+"\x00" {
				t.Error("logger did not retain its profile")
			}
			logger.Printf("disabled")
		}(profile)
	}
	workers.Wait()
	newDeviceLogger(nil, "11111111-1111-1111-1111-111111111111")
	if signalLogger.Load().profile != nil {
		t.Fatal("signal logger has profile")
	}
}
