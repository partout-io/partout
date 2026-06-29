// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCrypto_C
@testable import PartoutCore

final class CryptoWrapper {
    enum Backend {
        case mock
#if PARTOUT_CRYPTO_OPENSSL
        case openSSL
#endif
#if PARTOUT_CRYPTO_MBEDTLS
        case mbedTLS
        case native
#endif

        var functionTable: pp_crypto_fnt {
            switch self {
            case .mock:
                pp_crypto_fnt_mock()
#if PARTOUT_CRYPTO_OPENSSL
            case .openSSL:
                pp_crypto_fnt_openssl()
#endif
#if PARTOUT_CRYPTO_MBEDTLS
            case .mbedTLS:
                pp_crypto_fnt_mbed()
            case .native:
                pp_crypto_fnt_native()
#endif
            }
        }
    }

    private let tbl: pp_crypto_enc_fnt
    private let ptr: pp_crypto_ctx
    private let free_fn: pp_crypto_free_fn

    init(
        _ backend: Backend,
        withAEADCipherName cipherName: String,
        tagLength: Int,
        idLength: Int
    ) throws {
        tbl = backend.functionTable.enc
        guard let ptr = tbl.aead_create(cipherName, tagLength, idLength, nil) else {
            throw PPCryptoError()
        }
        print("PartoutOpenVPN: Using CryptoAEAD (native Swift/C)")
        self.ptr = ptr
        free_fn = tbl.aead_free
    }

    init(
        _ backend: Backend,
        withCBCCipherName cipherName: String?,
        digestName: String
    ) throws {
        tbl = backend.functionTable.enc
        guard let ptr = tbl.cbc_create(cipherName, digestName, nil) else {
            throw PPCryptoError()
        }
        print("PartoutOpenVPN: Using CryptoCBC (native Swift/C)")
        self.ptr = ptr
        free_fn = tbl.cbc_free
    }

    init(
        _ backend: Backend,
        withCTRCipherName cipherName: String,
        digestName: String,
        tagLength: Int,
        payloadLength: Int
    ) throws {
        tbl = backend.functionTable.enc
        guard let ptr = tbl.ctr_create(cipherName, digestName, tagLength, payloadLength, nil) else {
            throw PPCryptoError()
        }
        print("PartoutOpenVPN: Using CryptoCTR (native Swift/C)")
        self.ptr = ptr
        free_fn = tbl.ctr_free
    }

    deinit {
        free_fn(ptr)
    }

    func encryptionCapacity(for length: Int) -> Int {
        pp_crypto_encryption_capacity(ptr, length)
    }

    func configureEncryption(withCipherKey cipherKey: CZeroingData?, hmacKey: CZeroingData?) {
        pp_crypto_configure_encrypt(ptr, cipherKey?.ptr, hmacKey?.ptr)
    }

    func encryptBytes(_ bytes: UnsafePointer<UInt8>, length: Int, dest: CZeroingData, flags: UnsafePointer<pp_crypto_flags>?) throws -> Int {
        var code = PPCryptoErrorNone
        let destLength = pp_crypto_encrypt(ptr, dest.mutableBytes, dest.count, bytes, length, flags, &code)
        guard destLength > 0 else {
            throw PPCryptoError(code)
        }
        return destLength
    }

    func configureDecryption(withCipherKey cipherKey: CZeroingData?, hmacKey: CZeroingData?) {
        pp_crypto_configure_decrypt(ptr, cipherKey?.ptr, hmacKey?.ptr)
    }

    func decryptBytes(_ bytes: UnsafePointer<UInt8>, length: Int, dest: CZeroingData, flags: UnsafePointer<pp_crypto_flags>?) throws -> Int {
        var code = PPCryptoErrorNone
        let destLength = pp_crypto_decrypt(ptr, dest.mutableBytes, dest.count, bytes, length, flags, &code)
        guard destLength > 0 else {
            throw PPCryptoError(code)
        }
        return destLength
    }

    func verifyBytes(_ bytes: UnsafePointer<UInt8>, length: Int, flags: UnsafePointer<pp_crypto_flags>?) throws -> Bool {
        var code = PPCryptoErrorNone
        guard pp_crypto_verify(ptr, bytes, length, &code) else {
            throw PPCryptoError(code)
        }
        return true
    }
}
