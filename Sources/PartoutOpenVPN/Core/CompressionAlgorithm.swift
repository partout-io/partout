// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension OpenVPN {

    /// Defines the type of compression algorithm.
    public enum CompressionAlgorithm: Int, Sendable {
        case disabled

        case LZO

        case other
    }
}

extension OpenVPN.CompressionAlgorithm: Codable {
}

extension OpenVPN.CompressionAlgorithm: CustomStringConvertible {
    public var description: String {
        switch self {
        case .disabled:
            return "disabled"

        case .LZO:
            return "lzo"

        case .other:
            return "other"

        @unknown default:
            return "unknown"
        }
    }
}
