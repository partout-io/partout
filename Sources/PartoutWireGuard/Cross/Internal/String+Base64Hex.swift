// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension String {
    var hexStringFromBase64: String {
        // FIXME: #199, fatalError() is a bit too much for base 64 -> 16
        guard let data = Data(base64Encoded: self) else { fatalError() }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
