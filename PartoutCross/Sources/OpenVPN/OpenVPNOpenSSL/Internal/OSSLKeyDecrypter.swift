//
//  OSSLKeyDecrypter.swift
//  Partout
//
//  Created by Davide De Rosa on 6/27/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import _PartoutOpenVPNCore
internal import _PartoutOpenVPNOpenSSL_C
import PartoutCore

final class OSSLKeyDecrypter: KeyDecrypter, Sendable {
    func decryptedKey(fromPEM pem: String, passphrase: String) throws -> String {
        let buf = pem.withCString { cPEM in
            passphrase.withCString { cPassphrase in
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
            passphrase.withCString { cPassphrase in
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
