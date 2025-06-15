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

public final class CryptoAEAD: Encrypter, Decrypter {
    private let ptr: UnsafeMutablePointer<crypto_aead_t>

    private let mappedError: (CryptoError) -> Error

    public init(
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

    public var digestLength: Int {
        ptr.pointee.meta.digest_length
    }

    public var tagLength: Int {
        ptr.pointee.meta.tag_length
    }

    public func encryptionCapacity(for length: Int) -> Int {
        ptr.pointee.meta.encryption_capacity(ptr, length)
    }

    public func configureEncryption(withCipherKey cipherKey: ZeroingData?, hmacKey: ZeroingData?) {
        guard let cipherKey, let hmacKey else {
            return
        }
        ptr.pointee.encrypter.configure(ptr, cipherKey.ptr, hmacKey.ptr)
    }

    func encryptBytes(_ bytes: UnsafePointer<UInt8>, length: Int, dest: UnsafeMutablePointer<UInt8>, destLength: UnsafeMutablePointer<Int>, flags: UnsafePointer<crypto_flags_t>?) throws -> Bool {
        var code = CryptoErrorGeneric
        guard ptr.pointee.encrypter.encrypt(ptr, bytes, length, dest, destLength, flags, &code) else {
            throw mappedError(CryptoError(code))
        }
        return true
    }

    public func configureDecryption(withCipherKey cipherKey: ZeroingData?, hmacKey: ZeroingData?) {
        guard let cipherKey, let hmacKey else {
            return
        }
        ptr.pointee.decrypter.configure(ptr, cipherKey.ptr, hmacKey.ptr)
    }

    func decryptBytes(_ bytes: UnsafePointer<UInt8>, length: Int, dest: UnsafeMutablePointer<UInt8>, destLength: UnsafeMutablePointer<Int>, flags: UnsafePointer<crypto_flags_t>?) throws -> Bool {
        var code = CryptoErrorGeneric
        guard ptr.pointee.decrypter.decrypt(ptr, bytes, length, dest, destLength, flags, &code) else {
            throw mappedError(CryptoError(code))
        }
        return true
    }

    public func verifyBytes(_ bytes: UnsafePointer<UInt8>, length: Int) throws -> Bool {
        fatalError("Unsupported")
    }

    func verifyBytes(_ bytes: UnsafePointer<UInt8>, length: Int, flags: UnsafePointer<crypto_flags_t>?) throws -> Bool {
        fatalError("Unsupported")
    }
}
