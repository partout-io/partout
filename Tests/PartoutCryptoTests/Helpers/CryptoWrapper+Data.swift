// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCrypto_C
import PartoutCore

extension CryptoWrapper {
    func encryptData(_ data: CZeroingData, flags: UnsafePointer<pp_crypto_flags>?) throws -> CZeroingData {
        let dest = CZeroingData(count: data.count + 256)
        let destLength = try encryptBytes(
            data.bytes,
            length: data.count,
            dest: dest,
            flags: flags
        )
        dest.resize(toSize: destLength)
        return dest
    }
}

extension CryptoWrapper {
    func decryptData(_ data: CZeroingData, flags: UnsafePointer<pp_crypto_flags>?) throws -> CZeroingData {
        let dest = CZeroingData(count: data.count + 256)
        let destLength = try decryptBytes(
            data.bytes,
            length: data.count,
            dest: dest,
            flags: flags
        )
        dest.resize(toSize: destLength)
        return dest
    }

    func verifyData(_ data: CZeroingData, flags: UnsafePointer<pp_crypto_flags>?) throws {
        _ = try verifyBytes(data.bytes, length: data.count, flags: flags)
    }
}
