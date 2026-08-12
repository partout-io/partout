// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Provides a way to decrypt a PEM private key.
public protocol KeyDecrypter {
    func decryptedKey(fromPEM pem: String, passphrase: String) throws -> String
}
