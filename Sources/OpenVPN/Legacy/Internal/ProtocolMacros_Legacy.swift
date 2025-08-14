// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

enum ProtocolMacros {

    // UInt32(0) + UInt8(KeyMethod = 2)
    static let tlsPrefix = Data(hex: "0000000002")

    private static let numberOfKeys = UInt8(8) // 3-bit

    static func nextKey(after currentKey: UInt8) -> UInt8 {
        max(1, (currentKey + 1) % numberOfKeys)
    }

    static let pingString = Data(hex: "2a187bf3641eb4cb07ed2d0a981fc748")
}
