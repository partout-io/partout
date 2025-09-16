// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// Use newer C-based implementation, which comes with extensions
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOS
#endif

typealias CrossPacket = CControlPacket
typealias CrossPacketCode = CPacketCode
typealias CrossPacketProtocol = CPacketProtocol
typealias CrossZD = CZeroingData

extension PRNGProtocol {
    func safeCrossData(length: Int) -> CrossZD {
        CZ(data(length: length))
    }
}

extension CrossPacketProtocol {
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.packetId < rhs.packetId
    }
}

extension CrossPacket: CrossPacketProtocol {}
