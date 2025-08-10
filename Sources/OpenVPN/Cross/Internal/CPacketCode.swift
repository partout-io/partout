// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
import Foundation

enum CPacketCode: UInt8 {
    case softResetV1           = 0x03
    case controlV1             = 0x04
    case ackV1                 = 0x05
    case dataV1                = 0x06
    case hardResetClientV2     = 0x07
    case hardResetServerV2     = 0x08
    case dataV2                = 0x09
    case unknown               = 0xff
}

extension CPacketCode: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case .softResetV1:          return "SOFT_RESET_V1"
        case .controlV1:            return "CONTROL_V1"
        case .ackV1:                return "ACK_V1"
        case .dataV1:               return "DATA_V1"
        case .hardResetClientV2:    return "HARD_RESET_CLIENT_V2"
        case .hardResetServerV2:    return "HARD_RESET_SERVER_V2"
        case .dataV2:               return "DATA_V2"
        case .unknown:              return "UNKNOWN(\(rawValue))"
        @unknown default:           return "UNKNOWN(\(rawValue))"
        }
    }
}

extension CPacketCode {
    var native: openvpn_packet_code {
        switch self {
        case .softResetV1:          PacketCodeSoftResetV1
        case .controlV1:            PacketCodeControlV1
        case .ackV1:                PacketCodeAckV1
        case .dataV1:               PacketCodeDataV1
        case .hardResetClientV2:    PacketCodeHardResetClientV2
        case .hardResetServerV2:    PacketCodeHardResetServerV2
        case .dataV2:               PacketCodeDataV2
        case .unknown:              PacketCodeUnknown
        }
    }
}
