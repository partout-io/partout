// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Provides a way to decrypt a PEM private key.
public protocol KeyDecrypter: Sendable {
    func decryptedKey(fromPEM pem: String, passphrase: String) throws -> String
}
