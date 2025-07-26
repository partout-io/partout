// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPNLegacy_ObjC
import PartoutOpenVPN

extension OpenVPN.CompressionAlgorithm {
    var native: CompressionAlgorithm {
        switch self {
        case .disabled: .disabled
        case .LZO: .LZO
        case .other: .other
        @unknown default: .disabled
        }
    }
}

extension OpenVPN.CompressionFraming {
    var native: CompressionFraming {
        switch self {
        case .disabled: .disabled
        case .compLZO: .compLZO
        case .compress: .compress
        case .compressV2: .compressV2
        @unknown default: .disabled
        }
    }
}
