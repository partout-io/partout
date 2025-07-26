// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutVendorsPortable
import Foundation
import PartoutCore

extension SecureData {
    var czData: CZeroingData {
        CZ(toData())
    }
}

extension CZeroingData: SensitiveDebugStringConvertible {
    func debugDescription(withSensitiveData: Bool) -> String {
        withSensitiveData ? "[\(count) bytes, \(toHex())]" : "[\(count) bytes]"
    }
}
