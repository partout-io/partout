// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
internal import _PartoutOpenVPNLegacy_ObjC
#endif
import Foundation

extension PacketProtocol {
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.packetId < rhs.packetId
    }
}
