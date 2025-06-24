//
//  PacketCode.swift
//  Partout
//
//  Created by Davide De Rosa on 6/15/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation

// FIXME: ###, packet_code_t, look into something like NS_ENUM but in C
enum PacketCode: UInt8 {
    case softResetV1           = 0x03
    case controlV1             = 0x04
    case ackV1                 = 0x05
    case dataV1                = 0x06
    case hardResetClientV2     = 0x07
    case hardResetServerV2     = 0x08
    case dataV2                = 0x09
    case unknown               = 0xff
}

extension PacketCode: CustomDebugStringConvertible {
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
