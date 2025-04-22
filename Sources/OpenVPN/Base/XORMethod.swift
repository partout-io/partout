//
//  XORMethod.swift
//  Partout
//
//  Created by Davide De Rosa on 11/4/22.
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
import PartoutCore

extension OpenVPN {

    /// The obfuscation method.
    public enum XORMethod: Hashable, Codable, Sendable {

        /// XORs the bytes in each buffer with the given mask.
        case xormask(mask: SecureData)

        /// XORs each byte with its position in the packet.
        case xorptrpos

        /// Reverses the order of bytes in each buffer except for the first (abcde becomes aedcb).
        case reverse

        /// Performs several of the above steps (xormask -> xorptrpos -> reverse -> xorptrpos).
        case obfuscate(mask: SecureData)

        /// The optionally associated mask.
        public var mask: SecureData? {
            switch self {
            case .xormask(let mask):
                return mask

            case .obfuscate(let mask):
                return mask

            default:
                return nil
            }
        }
    }
}
