// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_STATIC
internal import _PartoutOpenVPNLegacy_ObjC
import PartoutOpenVPN
#endif

extension OpenVPN.CompressionFraming {
    var legacyNative: CompressionFraming {
        switch self {
        case .disabled: .disabled
        case .compLZO: .compLZO
        case .compress: .compress
        case .compressV2: .compressV2
        @unknown default: .disabled
        }
    }
}
