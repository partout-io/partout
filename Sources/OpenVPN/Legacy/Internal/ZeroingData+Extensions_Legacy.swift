// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_STATIC
internal import _PartoutCryptoOpenSSL_ObjC
import PartoutCore
#endif

extension PRNGProtocol {
    func safeData(length: Int) -> ZeroingData {
        precondition(length > 0)
        let randomBytes = pp_alloc_crypto(length)
        defer {
            bzero(randomBytes, length)
            free(randomBytes)
        }
        guard SecRandomCopyBytes(kSecRandomDefault, length, randomBytes) == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed")
        }
        return Z(Data(bytes: randomBytes, count: length))
    }
}

extension SecureData {
    var zData: ZeroingData {
        Z(toData())
    }
}

extension ZeroingData: @retroactive SensitiveDebugStringConvertible {
    func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? "[\(length) bytes, \(toHex())]" : "[\(length) bytes]"
    }
}
