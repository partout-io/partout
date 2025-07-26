// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCryptoOpenSSL_ObjC
import PartoutCore

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
