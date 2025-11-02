// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0


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
