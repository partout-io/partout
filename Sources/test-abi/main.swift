// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import Partout

let ver = String(cString: partout_version())
print("Version: \(ver)")
