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

internal import _PartoutVendorsPortable

// NOTE: it doesn't matter to use Swift CryptoFlagsWrapper here. for
// efficiency reasons, OpenVPN will use the C API directly without
// going through Encrypter/Decrypter

protocol Crypto {
    /// The preferred capacity for storing encrypted data.
    /// - Parameter length: The number of bytes to encrypt.
    func encryptionCapacity(for length: Int) -> Int
}

protocol Encrypter: Crypto {
    /// Configures the object.
    /// - Parameters:
    ///   - cipherKey: The cipher key data.
    ///   - hmacKey: The HMAC key data.
    func configureEncryption(withCipherKey cipherKey: CZeroingData?, hmacKey: CZeroingData?)

    /// Encrypts a buffer.
    /// - Parameters:
    ///   - bytes: Bytes to encrypt.
    ///   - length: The number of bytes.
    ///   - dest: The destination buffer.
    ///   - flags: The optional encryption flags.
    func encryptBytes(
        _ bytes: UnsafePointer<UInt8>,
        length: Int,
        dest: CZeroingData,
        flags: CryptoFlagsWrapper?
    ) throws -> Int
}

protocol Decrypter: Crypto {
    /// Configures the object.
    /// - Parameters:
    ///   - cipherKey: The cipher key data.
    ///   - hmacKey: The HMAC key data.
    func configureDecryption(withCipherKey cipherKey: CZeroingData?, hmacKey: CZeroingData?)

    /// Decrypts a buffer.
    /// - Parameters:
    ///   - bytes: Bytes to decrypt.
    ///   - length: The number of bytes.
    ///   - dest: The destination buffer.
    ///   - flags: The optional encryption flags.
    func decryptBytes(
        _ bytes: UnsafePointer<UInt8>,
        length: Int,
        dest: CZeroingData,
        flags: CryptoFlagsWrapper?
    ) throws -> Int

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
