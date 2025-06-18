//
//  CryptoAEAD.swift
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

internal import _PartoutCryptoOpenSSL_C
import Foundation

final class CryptoAEAD: Encrypter, Decrypter {
    private let ptr: UnsafeMutablePointer<crypto_aead_t>

    private let mappedError: (CryptoError) -> Error

    init(
        cipherName: String,
        tagLength: Int,
        idLength: Int,
        mappedError: ((CryptoError) -> Error)? = nil
    ) throws {
        guard let ptr = crypto_aead_create(cipherName, tagLength, idLength) else {
            throw CryptoError()
        }
        NSLog("PartoutOpenVPN: Using CryptoAEAD (Swift)")
        self.ptr = ptr
        self.mappedError = mappedError ?? { $0 }
    }

    var digestLength: Int {
        ptr.pointee.crypto.meta.digest_len
    }

    var tagLength: Int {
        ptr.pointee.crypto.meta.tag_len
    }

    func encryptionCapacity(for length: Int) -> Int {
        ptr.pointee.crypto.meta.encryption_capacity(ptr, length)
    }

    func configureEncryption(withCipherKey cipherKey: ZeroingData?, hmacKey: ZeroingData?) {
        guard let cipherKey, let hmacKey else {
            return
        }
        ptr.pointee.crypto.encrypter.configure(ptr, cipherKey.ptr, hmacKey.ptr)
    }

    func encryptBytes(_ bytes: UnsafePointer<UInt8>, length: Int, dest: UnsafeMutablePointer<UInt8>, destLength: UnsafeMutablePointer<Int>, flags: CryptoFlagsWrapper?) throws -> Bool {
        var code = CryptoErrorGeneric
        var cFlags = crypto_flags_t()
        let flagsPtr = flags.pointer(to: &cFlags)
        guard ptr.pointee.crypto.encrypter.encrypt(ptr, dest, destLength, bytes, length, flagsPtr, &code) else {
            throw mappedError(CryptoError(code))
        }
        return true
    }

    func configureDecryption(withCipherKey cipherKey: ZeroingData?, hmacKey: ZeroingData?) {
        guard let cipherKey, let hmacKey else {
            return
        }
        ptr.pointee.crypto.decrypter.configure(ptr, cipherKey.ptr, hmacKey.ptr)
    }

    func decryptBytes(_ bytes: UnsafePointer<UInt8>, length: Int, dest: UnsafeMutablePointer<UInt8>, destLength: UnsafeMutablePointer<Int>, flags: CryptoFlagsWrapper?) throws -> Bool {
        var code = CryptoErrorGeneric
        var cFlags = crypto_flags_t()
        let flagsPtr = flags.pointer(to: &cFlags)
        guard ptr.pointee.crypto.decrypter.decrypt(ptr, dest, destLength, bytes, length, flagsPtr, &code) else {
            throw mappedError(CryptoError(code))
        }
        return true
    }

    func verifyBytes(_ bytes: UnsafePointer<UInt8>, length: Int, flags: CryptoFlagsWrapper?) throws -> Bool {
        fatalError("Unsupported")
    }
}
