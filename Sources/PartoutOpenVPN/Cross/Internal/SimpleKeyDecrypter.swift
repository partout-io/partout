// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOpenVPN_C
#if !PARTOUT_MONOLITH
import PartoutCore
import PartoutOpenVPN
#endif

final class SimpleKeyDecrypter: KeyDecrypter, Sendable {
    func decryptedKey(fromPEM pem: String, passphrase: String) throws -> String {
        let buf = pem.withCString { cPEM in
            passphrase.withCString { cPassphrase in
                pp_key_decrypted_from_pem(cPEM, cPassphrase)
            }
        }
        guard let buf else {
            throw PPCryptoError.creation
        }
        let str = String(cString: buf)
        pp_zero(buf, str.count)
        free(buf)
        return str
    }

    func decryptedKey(fromPath path: String, passphrase: String) throws -> String {
        let buf = path.withCString { cPath in
            passphrase.withCString { cPassphrase in
                pp_key_decrypted_from_path(cPath, cPassphrase)
            }
        }
        guard let buf else {
            throw PPCryptoError.creation
        }
        let str = String(cString: buf)
        pp_zero(buf, str.count)
        free(buf)
        return str
    }
}
