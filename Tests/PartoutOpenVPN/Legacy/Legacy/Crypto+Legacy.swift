// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCryptoOpenSSL_ObjC
import Foundation

extension Encrypter {
    func encryptData(_ data: Data, flags: UnsafePointer<CryptoFlags>?) throws -> Data {
        let srcLength = data.count
        var dest: [UInt8] = Array(repeating: 0, count: srcLength + 256)
        var destLength = 0
        _ = try data.withUnsafeBytes {
            try encryptBytes($0.bytePointer, length: srcLength, dest: &dest, destLength: &destLength, flags: flags)
        }
        dest.removeSubrange(destLength..<dest.count)
        return Data(dest)
    }
}

extension Decrypter {
    func decryptData(_ data: Data, flags: UnsafePointer<CryptoFlags>?) throws -> Data {
        let srcLength = data.count
        var dest: [UInt8] = Array(repeating: 0, count: srcLength + 256)
        var destLength = 0
        _ = try data.withUnsafeBytes {
            try decryptBytes($0.bytePointer, length: srcLength, dest: &dest, destLength: &destLength, flags: flags)
        }
        dest.removeSubrange(destLength..<dest.count)
        return Data(dest)
    }

    func verifyData(_ data: Data, flags: UnsafePointer<CryptoFlags>?) throws {
        let srcLength = data.count
        _ = try data.withUnsafeBytes {
            try verifyBytes($0.bytePointer, length: srcLength, flags: flags)
        }
    }
}

extension Encrypter {
    func encryptData(_ data: Data) throws -> Data {
        try encryptData(data, flags: nil as UnsafePointer<CryptoFlags>?)
    }
}

extension Decrypter {
    func decryptData(_ data: Data) throws -> Data {
        try decryptData(data, flags: nil as UnsafePointer<CryptoFlags>?)
    }

    func verifyData(_ data: Data) throws {
        try verifyData(data, flags: nil as UnsafePointer<CryptoFlags>?)
    }
}
