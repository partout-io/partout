// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPNLegacy_ObjC
import Foundation

extension PacketProtocol {
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.packetId < rhs.packetId
    }
}
