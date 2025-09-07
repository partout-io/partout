// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension String {
    var hexStringFromBase64: String {
        // FIXME: #93, fatalError() is a bit too much
        guard let data = Data(base64Encoded: self) else { fatalError() }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
