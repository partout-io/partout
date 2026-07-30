// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutPortable_C

/// Helper for handling IP headers.
public struct IPHeader {
    private init() {
    }

    public static func protocolNumber(inPacket packet: Data) -> UInt32 {
        guard !packet.isEmpty else {
            return fallbackProtocolNumber
        }
        let version = (packet[0] & 0xf0) >> 4
        assert(version == ipV4Version || version == ipV6Version)
        return (version == ipV6Version) ? ipV6ProtocolNumber : ipV4ProtocolNumber
    }
}

private extension IPHeader {
    static let ipV4Version: UInt8 = 4
    static let ipV6Version: UInt8 = 6
    static let ipV4ProtocolNumber = UInt32(AF_INET)
    static let ipV6ProtocolNumber = UInt32(AF_INET6)
    static let fallbackProtocolNumber = ipV4ProtocolNumber
}
