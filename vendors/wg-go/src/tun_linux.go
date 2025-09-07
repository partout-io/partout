/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2025 Davide De Rosa. All Rights Reserved.
 */

package main

import (
	"golang.zx2c4.com/wireguard/tun"
)

func wgCreateTun(tunFd int) (tun.Device, error) {
	tun, _, err := tun.CreateUnmonitoredTUNFromFD(tunFd)
	if err != nil {
		return nil, err
	}
	return tun, nil
}
