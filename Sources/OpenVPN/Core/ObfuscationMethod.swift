// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

extension OpenVPN {

    /// The obfuscation method.
    public enum ObfuscationMethod: Hashable, Codable, Sendable {

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
