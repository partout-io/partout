//
//  CryptoProtocols.swift
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

@testable internal import _PartoutCryptoOpenSSL_C
import Foundation

// NOTE: it doesn't matter to use Swift CryptoFlagsWrapper here. for
// efficiency reasons, OpenVPN will use the C API directly without
// going through Encrypter/Decrypter

protocol Crypto {
    /// The digest length or 0.
    var digestLength: Int { get }

    /// The tag length or 0.
    var tagLength: Int { get }

    /// The preferred encryption capacity.
    /// - Parameter length: The number of bytes to encrypt.
    func encryptionCapacity(for length: Int) -> Int
}

protocol Encrypter: Crypto {
    /// Configures the object.
    /// - Parameters:
    ///   - cipherKey: The cipher key data.
    ///   - hmacKey: The HMAC key data.
    func configureEncryption(withCipherKey cipherKey: ZeroingData?, hmacKey: ZeroingData?)

    /// Encrypts a buffer.
    /// - Parameters:
    ///   - bytes: Bytes to encrypt.
    ///   - length: The number of bytes.
    ///   - dest: The destination buffer.
    ///   - destLength: The number of bytes written to `dest`.
    ///   - flags: The optional encryption flags.
    func encryptBytes(
        _ bytes: UnsafePointer<UInt8>,
        length: Int,
        dest: UnsafeMutablePointer<UInt8>,
        destLength: UnsafeMutablePointer<Int>,
        flags: CryptoFlagsWrapper?
    ) throws -> Bool
}

protocol Decrypter: Crypto {
    /// Configures the object.
    /// - Parameters:
    ///   - cipherKey: The cipher key data.
    ///   - hmacKey: The HMAC key data.
    func configureDecryption(withCipherKey cipherKey: ZeroingData?, hmacKey: ZeroingData?)

    /// Decrypts a buffer.
    /// - Parameters:
    ///   - bytes: Bytes to decrypt.
    ///   - length: The number of bytes.
    ///   - dest: The destination buffer.
    ///   - destLength: The number of bytes written to `dest`.
    ///   - flags: The optional encryption flags.
    func decryptBytes(
        _ bytes: UnsafePointer<UInt8>,
        length: Int,
        dest: UnsafeMutablePointer<UInt8>,
        destLength: UnsafeMutablePointer<Int>,
        flags: CryptoFlagsWrapper?
    ) throws -> Bool

    /// Verifies an encrypted buffer.
    /// - Parameters:
    ///   - bytes: Bytes to decrypt.
    ///   - length: The number of bytes.
    ///   - flags: The optional encryption flags.
    func verifyBytes(
        _ bytes: UnsafePointer<UInt8>,
        length: Int,
        flags: CryptoFlagsWrapper?
    ) throws -> Bool
}
