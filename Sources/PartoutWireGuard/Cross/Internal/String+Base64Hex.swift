// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension String {
    func hexStringFromBase64() throws -> String {
        guard let data = Data(base64Encoded: self) else {
            throw PartoutError(.parsing)
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
