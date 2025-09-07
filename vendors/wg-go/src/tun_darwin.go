/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2025 Davide De Rosa. All Rights Reserved.
 */

package main

import (
	"os"
	"golang.zx2c4.com/wireguard/tun"
)

func wgCreateTun(tunFd int) (tun.Device, error) {
	tun, err := tun.CreateTUNFromFile(os.NewFile(uintptr(tunFd), "/dev/tun"), 0)
	if err != nil {
		return nil, err
	}
	return tun, nil
}
