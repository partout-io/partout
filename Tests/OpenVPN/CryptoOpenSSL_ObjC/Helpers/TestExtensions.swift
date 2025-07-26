// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCryptoOpenSSL_ObjC
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
}

protocol CryptoFlagsProviding {
    var packetId: [UInt8] { get }

    var ad: [UInt8] { get }
}

extension CryptoFlagsProviding {
    func withCryptoFlags<T>(_ block: (UnsafePointer<CryptoFlags>) throws -> T) rethrows -> T {
        try packetId.withUnsafeBufferPointer { iv in
            try ad.withUnsafeBufferPointer { ad in
                var flags = CryptoFlags(
                    iv: iv.baseAddress,
                    ivLength: iv.count,
                    ad: ad.baseAddress,
                    adLength: ad.count,
                    forTesting: true
                )
                return try block(&flags)
            }
        }
    }
}
