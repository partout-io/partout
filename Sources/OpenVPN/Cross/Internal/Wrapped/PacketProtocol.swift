// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(_PartoutOpenVPNLegacy_ObjC)
#if !PARTOUT_STATIC
internal import _PartoutOpenVPNLegacy_ObjC
#endif
#else
protocol PacketProtocol {
    var packetId: UInt32 { get }
}

extension PacketProtocol {
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.packetId < rhs.packetId
    }
}
#endif

extension CControlPacket: PacketProtocol {
}
