//
//  CompressionFraming.swift
//  Partout
//
//  Created by Davide De Rosa on 8/30/18.
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

extension OpenVPN {

    /// Defines the type of compression framing.
    public enum CompressionFraming: Int, Sendable {
        case disabled

        case compLZO

        case compress

        case compressV2
    }
}

extension OpenVPN.CompressionFraming: Codable {
}

extension OpenVPN.CompressionFraming: CustomStringConvertible {
    public var description: String {
        switch self {
        case .disabled:
            return "disabled"

        case .compress:
            return "compress"

        case .compressV2:
            return "compress"

        case .compLZO:
            return "comp-lzo"

        @unknown default:
            return "unknown"
        }
    }
}
