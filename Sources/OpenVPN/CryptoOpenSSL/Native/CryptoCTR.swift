//
//  CCryptoCTR.swift
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

public final class CryptoCTR: Encrypter, Decrypter {
    private let ptr: UnsafeMutablePointer<crypto_ctr_t>

    private let mappedError: (CryptoError) -> Error

    public init(
        cipherName: String,
        digestName: String,
        tagLength: Int,
        payloadLength: Int,
        mappedError: ((CryptoError) -> Error)? = nil
    ) throws {
        guard let ptr = crypto_ctr_create(cipherName, digestName, tagLength, payloadLength) else {
            throw CryptoError()
        }
        NSLog("PartoutOpenVPN: Using CryptoCTR (Swift)")
        self.ptr = ptr
        self.mappedError = mappedError ?? { $0 }
    }

    public var digestLength: Int {
        ptr.pointee.crypto.meta.digest_length
    }

    public var tagLength: Int {
        ptr.pointee.crypto.meta.tag_length
    }

    public func encryptionCapacity(for length: Int) -> Int {
        ptr.pointee.crypto.meta.encryption_capacity(ptr, length)
    }

    public func configureEncryption(withCipherKey cipherKey: ZeroingData?, hmacKey: ZeroingData?) {
        guard let cipherKey, let hmacKey else {
            return
        }
        ptr.pointee.crypto.encrypter.configure(ptr, cipherKey.ptr, hmacKey.ptr)
    }

    public func encryptBytes(_ bytes: UnsafePointer<UInt8>, length: Int, dest: UnsafeMutablePointer<UInt8>, destLength: UnsafeMutablePointer<Int>, flags: CryptoFlagsWrapper?) throws -> Bool {
        var code = CryptoErrorGeneric
        var cFlags = crypto_flags_t()
        let flagsPtr = flags.pointer(to: &cFlags)
        guard ptr.pointee.crypto.encrypter.encrypt(ptr, dest, destLength, bytes, length, flagsPtr, &code) else {
            throw mappedError(CryptoError(code))
        }
        return true
    }

    public func configureDecryption(withCipherKey cipherKey: ZeroingData?, hmacKey: ZeroingData?) {
        guard let cipherKey, let hmacKey else {
            return
        }
        ptr.pointee.crypto.decrypter.configure(ptr, cipherKey.ptr, hmacKey.ptr)
    }

    public func decryptBytes(_ bytes: UnsafePointer<UInt8>, length: Int, dest: UnsafeMutablePointer<UInt8>, destLength: UnsafeMutablePointer<Int>, flags: CryptoFlagsWrapper?) throws -> Bool {
        var code = CryptoErrorGeneric
        var cFlags = crypto_flags_t()
        let flagsPtr = flags.pointer(to: &cFlags)
        guard ptr.pointee.crypto.decrypter.decrypt(ptr, dest, destLength, bytes, length, flagsPtr, &code) else {
            throw mappedError(CryptoError(code))
        }
        return true
    }

    public func verifyBytes(_ bytes: UnsafePointer<UInt8>, length: Int, flags: CryptoFlagsWrapper?) throws -> Bool {
        fatalError("Unsupported")
    }
}
