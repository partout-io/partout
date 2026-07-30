// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

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
