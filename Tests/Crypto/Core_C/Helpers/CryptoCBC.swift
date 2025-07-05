//
//  CCryptoCBC.swift
//  Partout
//
//  Created by Davide De Rosa on 6/14/25.
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

@testable internal import _PartoutCryptoCore
internal import _PartoutCryptoCore_C
import Foundation

final class CryptoCBC: Encrypter, Decrypter {
    private let ptr: crypto_ctx

    init(
        cipherName: String?,
        digestName: String
    ) throws {
        guard let ptr = crypto_cbc_create(cipherName, digestName, nil) else {
            throw CryptoError()
        }
        NSLog("PartoutOpenVPN: Using CryptoCBC (native Swift/C)")
        self.ptr = ptr
    }

    deinit {
        crypto_cbc_free(ptr)
    }

    func encryptionCapacity(for length: Int) -> Int {
        crypto_encryption_capacity(ptr, length)
    }

    func configureEncryption(withCipherKey cipherKey: CZeroingData?, hmacKey: CZeroingData?) {
        guard let hmacKey else {
            fatalError("HMAC key required")
        }
        crypto_configure_encrypt(ptr, cipherKey?.ptr, hmacKey.ptr)
    }

    func encryptBytes(_ bytes: UnsafePointer<UInt8>, length: Int, dest: UnsafeMutablePointer<UInt8>, destLength: UnsafeMutablePointer<Int>, flags: CryptoFlagsWrapper?) throws -> Bool {
        var code = CryptoErrorNone
        var cFlags = crypto_flags_t()
        let flagsPtr = flags.pointer(to: &cFlags)
        guard crypto_encrypt(ptr, dest, destLength, bytes, length, flagsPtr, &code) else {
            throw CryptoError(code)
        }
        return true
    }

    func configureDecryption(withCipherKey cipherKey: CZeroingData?, hmacKey: CZeroingData?) {
        guard let hmacKey else {
            fatalError("HMAC key required")
        }
        crypto_configure_decrypt(ptr, cipherKey?.ptr, hmacKey.ptr)
    }

    func decryptBytes(_ bytes: UnsafePointer<UInt8>, length: Int, dest: UnsafeMutablePointer<UInt8>, destLength: UnsafeMutablePointer<Int>, flags: CryptoFlagsWrapper?) throws -> Bool {
        var code = CryptoErrorNone
        var cFlags = crypto_flags_t()
        let flagsPtr = flags.pointer(to: &cFlags)
        guard crypto_decrypt(ptr, dest, destLength, bytes, length, flagsPtr, &code) else {
            throw CryptoError(code)
        }
        return true
    }

    func verifyBytes(_ bytes: UnsafePointer<UInt8>, length: Int, flags: CryptoFlagsWrapper? = nil) throws -> Bool {
        var code = CryptoErrorNone
        guard crypto_verify(ptr, bytes, length, &code) else {
            throw CryptoError(code)
        }
        return true
    }
}
