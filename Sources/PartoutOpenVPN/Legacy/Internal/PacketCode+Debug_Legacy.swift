// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
internal import _PartoutOpenVPNLegacy_ObjC
#endif
import Foundation

extension PacketCode: @retroactive CustomDebugStringConvertible {
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
