// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCrypto_C
import Foundation

extension Data {
    init(hex: String) {
        assert(hex.count & 1 == 0)
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                data.append(byte)
            } else {
                break
            }
            index = nextIndex
        }
        self.init(data)
    }

    func toHex() -> String {
        var hexString = ""
        for i in 0..<count {
            hexString += String(format: "%02x", self[i])
        }
        return hexString
    }
}

struct CryptoFlags {
    var iv: [UInt8] = []

    var ad: [UInt8] = []
}

extension CryptoFlags {
    func withUnsafeFlags<T>(_ block: (UnsafePointer<pp_crypto_flags>) throws -> T) rethrows -> T {
        try iv.withUnsafeBufferPointer { iv in
            try ad.withUnsafeBufferPointer { ad in
                var flags = pp_crypto_flags(
                    iv: iv.baseAddress,
                    iv_len: iv.count,
                    ad: ad.baseAddress,
                    ad_len: ad.count,
                    for_testing: 1
                )
                return try block(&flags)
            }
        }
    }
}
