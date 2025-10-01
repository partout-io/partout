// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if OPENVPN_DEPRECATED_LZO

import Foundation
internal import PartoutOpenVPN_C
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

final class LZO {
    private let lzo: pp_lzo

    init() {
        guard let lzo = pp_lzo_create() else {
            fatalError("Unable to initialize LZO")
        }
        self.lzo = lzo
    }

    deinit {
        pp_lzo_free(lzo)
    }

    func compressed(_ data: Data) throws -> Data {
        try data.withUnsafeBytes {
            var bufLength = 0
            guard let buf = pp_lzo_compress(lzo, &bufLength, $0.bytePointer, data.count) else {
                throw PartoutError(.OpenVPN.compressionMismatch)
            }
            return Data(bytes: buf, count: bufLength)
        }
    }

    func decompressed(_ data: Data) throws -> Data {
        try data.withUnsafeBytes {
            var bufLength = 0
            guard let buf = pp_lzo_decompress(lzo, &bufLength, $0.bytePointer, data.count) else {
                throw PartoutError(.OpenVPN.compressionMismatch)
            }
            return Data(bytes: buf, count: bufLength)
        }
    }
}

#endif
