// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
import PartoutCore
import PartoutOpenVPN

final class OSSLKeyDecrypter: KeyDecrypter, Sendable {
    func decryptedKey(fromPEM pem: String, passphrase: String) throws -> String {
        let buf = pem.withCString { cPEM in
            passphrase.withCString { _ in
                key_decrypted_from_pem(cPEM, passphrase)
            }
        }
        guard let buf else {
            throw CryptoError.creation
        }
        let str = String(cString: buf)
        pp_zero(buf, str.count)
        free(buf)
        return str
    }

    func decryptedKey(fromPath path: String, passphrase: String) throws -> String {
        let buf = path.withCString { cPath in
            passphrase.withCString { _ in
                key_decrypted_from_path(cPath, passphrase)
            }
        }
        guard let buf else {
            throw CryptoError.creation
        }
        let str = String(cString: buf)
        pp_zero(buf, str.count)
        free(buf)
        return str
    }
}
