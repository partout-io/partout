/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2026 Davide De Rosa. All Rights Reserved.
 */

package main

import (
	"github.com/amnezia-vpn/amneziawg-go/tun"
	"os"
)

func wgCreateTun(tunFd int) (tun.Device, error) {
	return tun.CreateTUNFromFile(os.NewFile(uintptr(tunFd), "/dev/tun"), 0)
}
