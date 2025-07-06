//
//  crypto_cbc.c
//  Partout
//
//  Created by Davide De Rosa on 7/3/25.
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

#include <assert.h>
#include <windows.h>
#include <bcrypt.h>
#include <string.h>
#include "crypto/allocation.h"
#include "crypto/crypto_cbc.h"

#pragma comment(lib, "bcrypt.lib")

#define HMACMaxLength (size_t)128

typedef struct {
    crypto_t crypto;

    BCRYPT_ALG_HANDLE hAlgCipher;
    BCRYPT_ALG_HANDLE hAlgHmac;
    BCRYPT_KEY_HANDLE hKeyEnc;
    BCRYPT_KEY_HANDLE hKeyDec;
    BCRYPT_HASH_HANDLE hHmacEnc;
    BCRYPT_HASH_HANDLE hHmacDec;
    size_t cipher_key_len;
    size_t cipher_iv_len;
    size_t hmac_key_len;
    size_t digest_len;

    uint8_t *_Nullable utf_cipher_name;
    uint8_t *_Nonnull utf_digest_name;
    zeroing_data_t *_Nonnull hmac_key_enc;
    zeroing_data_t *_Nonnull hmac_key_dec;
    uint8_t *_Nonnull buffer_hmac;
} crypto_cbc_ctx;

static
size_t local_encryption_capacity(const void *vctx, size_t input_len) {
    const crypto_cbc_ctx *ctx = (const crypto_cbc_ctx *)vctx;
    assert(ctx);
    return pp_alloc_crypto_capacity(input_len, ctx->digest_len + ctx->cipher_iv_len);
}

static
void local_configure_encrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    assert(ctx);
    assert(hmac_key && hmac_key->length >= ctx->hmac_key_len);

    if (ctx->hKeyEnc) {
        BCryptDestroyKey(ctx->hKeyEnc);
        ctx->hKeyEnc = NULL;
    }
    if (ctx->hAlgCipher) {
        NTSTATUS status = BCryptGenerateSymmetricKey(
            ctx->hAlgCipher,
            &ctx->hKeyEnc,
            NULL, 0,
            (PUCHAR)cipher_key->bytes,
            (ULONG)ctx->cipher_key_len,
            0
        );
        assert(BCRYPT_SUCCESS(status));
    }

    if (ctx->hmac_key_enc) {
        zd_free(ctx->hmac_key_enc);
    }
    ctx->hmac_key_enc = zd_create_from_data(hmac_key->bytes, ctx->hmac_key_len);
}

static
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags, crypto_error_code *error) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    assert(ctx);
    assert(ctx->hmac_key_enc);

    uint8_t *out_iv = out + ctx->digest_len;
    uint8_t *out_encrypted = out_iv + ctx->cipher_iv_len;
    ULONG enc_len = 0;
    size_t hmac_len = 0;

    NTSTATUS status;

    if (ctx->hAlgCipher) {
        if (!flags || !flags->for_testing) {
            if (!BCRYPT_SUCCESS(BCryptGenRandom(NULL, out_iv, (ULONG)ctx->cipher_iv_len, BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
                return 0;
            }
        }

        UCHAR buf[16];
        memcpy(buf, out_iv, ctx->cipher_iv_len);
        status = BCryptEncrypt(
            ctx->hKeyEnc,
            (PUCHAR)in, (ULONG)in_len,
            NULL,
            //out_iv, (ULONG)ctx->cipher_iv_len,
            buf, (ULONG)ctx->cipher_iv_len, // FIXME: ###, copy IV to buf (function has side effect)
            out_encrypted, out_buf_len - (out_encrypted - out),
            &enc_len,
            BCRYPT_BLOCK_PADDING
        );
        if (!BCRYPT_SUCCESS(status)) {
            if (error) *error = CryptoErrorEncryption;
            return 0;
        }
    } else {
        assert(out_encrypted == out_iv);
        memcpy(out_encrypted, in, in_len);
        enc_len = in_len;
    }

    status = BCryptCreateHash(
        ctx->hAlgHmac,
        &ctx->hHmacEnc,
        NULL, 0,
        ctx->hmac_key_enc->bytes, (ULONG)ctx->hmac_key_len,
        0
    );
    assert(BCRYPT_SUCCESS(status));
    status = BCryptHashData(ctx->hHmacEnc, out_iv, (ULONG)(enc_len + ctx->cipher_iv_len), 0);
    assert(BCRYPT_SUCCESS(status));
    status = BCryptFinishHash(ctx->hHmacEnc, out, (ULONG)ctx->digest_len, 0);
    assert(BCRYPT_SUCCESS(status));
    BCryptDestroyHash(ctx->hHmacEnc);
    ctx->hHmacEnc = NULL;

    const size_t out_len = enc_len + ctx->cipher_iv_len + ctx->digest_len;
    return out_len;
}

static
void local_configure_decrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    assert(ctx);
    assert(hmac_key && hmac_key->length >= ctx->hmac_key_len);

    if (ctx->hKeyDec) {
        BCryptDestroyKey(ctx->hKeyDec);
        ctx->hKeyDec = NULL;
    }
    if (ctx->hAlgCipher) {
        NTSTATUS status = BCryptGenerateSymmetricKey(
            ctx->hAlgCipher,
            &ctx->hKeyDec,
            NULL, 0,
            (PUCHAR)cipher_key->bytes,
            (ULONG)ctx->cipher_key_len,
            0
        );
        assert(BCRYPT_SUCCESS(status));
    }

    if (ctx->hmac_key_dec) {
        zd_free(ctx->hmac_key_dec);
    }
    ctx->hmac_key_dec = zd_create_from_data(hmac_key->bytes, ctx->hmac_key_len);
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags, crypto_error_code *error) {
    (void)flags;
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    assert(ctx);
    assert(ctx->hmac_key_dec);

    const uint8_t *iv = in + ctx->digest_len;
    const uint8_t *encrypted = in + ctx->digest_len + ctx->cipher_iv_len;
    ULONG dec_len = 0;
    size_t hmac_len = 0;

    // HMAC verify
    NTSTATUS status = BCryptCreateHash(
        ctx->hAlgHmac,
        &ctx->hHmacDec,
        NULL, 0,
        ctx->hmac_key_dec->bytes, (ULONG)ctx->hmac_key_len,
        0
    );
    assert(BCRYPT_SUCCESS(status));
    status = BCryptHashData(ctx->hHmacDec, (PUCHAR)(in + ctx->digest_len), (ULONG)(in_len - ctx->digest_len), 0);
    assert(BCRYPT_SUCCESS(status));
    status = BCryptFinishHash(ctx->hHmacDec, ctx->buffer_hmac, (ULONG)ctx->digest_len, 0);
    assert(BCRYPT_SUCCESS(status));
    BCryptDestroyHash(ctx->hHmacDec);
    ctx->hHmacDec = NULL;

    if (memcmp(ctx->buffer_hmac, in, ctx->digest_len) != 0) {
        if (error) *error = CryptoErrorHMAC;
        return 0;
    }

    ULONG out_len = 0;
    if (ctx->hAlgCipher) {
        // Decrypt with CNG padding
        status = BCryptDecrypt(
            ctx->hKeyDec,
            (PUCHAR)encrypted, (ULONG)(in_len - ctx->digest_len - ctx->cipher_iv_len),
            NULL,
            (PUCHAR)iv, (ULONG)ctx->cipher_iv_len,
            out, out_buf_len,
            &out_len,
            BCRYPT_BLOCK_PADDING
        );
        if (!BCRYPT_SUCCESS(status)) {
            if (error) *error = CryptoErrorEncryption;
            return 0;
        }
    } else {
        memcpy(out, in + ctx->digest_len, in_len - ctx->digest_len);
        out_len = in_len - ctx->digest_len;
    }
    return out_len;
}

static
bool local_verify(void *vctx, const uint8_t *in, size_t in_len, crypto_error_code *error) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    assert(ctx);
    size_t hmac_len = 0;
    NTSTATUS status = BCryptCreateHash(
        ctx->hAlgHmac,
        &ctx->hHmacDec,
        NULL, 0,
        ctx->hmac_key_dec->bytes, (ULONG)ctx->hmac_key_len,
        0
    );
    assert(BCRYPT_SUCCESS(status));
    status = BCryptHashData(ctx->hHmacDec, (PUCHAR)(in + ctx->digest_len), (ULONG)(in_len - ctx->digest_len), 0);
    assert(BCRYPT_SUCCESS(status));
    status = BCryptFinishHash(ctx->hHmacDec, ctx->buffer_hmac, (ULONG)ctx->digest_len, 0);
    assert(BCRYPT_SUCCESS(status));
    BCryptDestroyHash(ctx->hHmacDec);
    ctx->hHmacDec = NULL;

    if (memcmp(ctx->buffer_hmac, in, ctx->digest_len) != 0) {
        if (error) *error = CryptoErrorHMAC;
        return false;
    }
    return true;
}

// MARK: -

crypto_ctx crypto_cbc_create(const char *cipher_name, const char *digest_name,
                             const crypto_keys_t *keys) {
    assert(digest_name);

    size_t cipher_key_len;
    size_t cipher_iv_len;
    LPCWSTR hmac_alg_id;
    size_t hmac_key_len;

    if (cipher_name) {
        if (!_stricmp(cipher_name, "AES-128-CBC")) {
            cipher_key_len = 16;
            cipher_iv_len = 16;
        } else if (!_stricmp(cipher_name, "AES-256-CBC")) {
            cipher_key_len = 32;
            cipher_iv_len = 16;
        } else {
            return NULL;
        }
    } else {
        cipher_key_len = 0;
        cipher_iv_len = 0;
    }
    if (!_stricmp(digest_name, "SHA1")) {
        hmac_alg_id = BCRYPT_SHA1_ALGORITHM;
        hmac_key_len = 20;
    } else if (!_stricmp(digest_name, "SHA256")) {
        hmac_alg_id = BCRYPT_SHA256_ALGORITHM;
        hmac_key_len = 32;
    } else if (!_stricmp(digest_name, "SHA512")) {
        hmac_alg_id = BCRYPT_SHA512_ALGORITHM;
        hmac_key_len = 64;
    } else {
        return NULL;
    }

    crypto_cbc_ctx *ctx = pp_alloc_crypto(sizeof(crypto_cbc_ctx));
    if (!ctx) {
        return NULL;
    }

    ctx->cipher_key_len = cipher_key_len;
    ctx->cipher_iv_len = cipher_iv_len;
    ctx->hmac_key_len = hmac_key_len;
    ctx->digest_len = ctx->hmac_key_len;

    ctx->utf_cipher_name = NULL;
    ctx->utf_digest_name = NULL;
    ctx->hKeyEnc = NULL;
    ctx->hKeyDec = NULL;
    ctx->hHmacEnc = NULL;
    ctx->hHmacDec = NULL;
    ctx->buffer_hmac = pp_alloc_crypto(HMACMaxLength);

    NTSTATUS status;
    if (cipher_name) {
        status = BCryptOpenAlgorithmProvider(
            &ctx->hAlgCipher,
            BCRYPT_AES_ALGORITHM,
            NULL,
            0
        );
        assert(BCRYPT_SUCCESS(status));
        status = BCryptSetProperty(
            ctx->hAlgCipher,
            BCRYPT_CHAINING_MODE,
            (PUCHAR)BCRYPT_CHAIN_MODE_CBC,
            (ULONG)sizeof(BCRYPT_CHAIN_MODE_CBC),
            0
        );
        assert(BCRYPT_SUCCESS(status));
    } else {
        ctx->hAlgCipher = NULL;
    }
    status = BCryptOpenAlgorithmProvider(
        &ctx->hAlgHmac,
        hmac_alg_id,
        NULL,
        BCRYPT_ALG_HANDLE_HMAC_FLAG
    );
    assert(BCRYPT_SUCCESS(status));

    ctx->crypto.meta.cipher_key_len = ctx->cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = ctx->cipher_iv_len;
    ctx->crypto.meta.hmac_key_len = ctx->hmac_key_len;
    ctx->crypto.meta.digest_len = ctx->digest_len;
    ctx->crypto.meta.tag_len = 0;
    ctx->crypto.meta.encryption_capacity = local_encryption_capacity;

    ctx->crypto.encrypter.configure = local_configure_encrypt;
    ctx->crypto.encrypter.encrypt = local_encrypt;
    ctx->crypto.decrypter.configure = local_configure_decrypt;
    ctx->crypto.decrypter.decrypt = local_decrypt;
    ctx->crypto.decrypter.verify = local_verify;

    if (keys) {
        local_configure_encrypt(ctx, keys->cipher.enc_key, keys->hmac.enc_key);
        local_configure_decrypt(ctx, keys->cipher.dec_key, keys->hmac.dec_key);
    }

    return (crypto_ctx)ctx;
}

void crypto_cbc_free(crypto_ctx vctx) {
    if (!vctx) return;
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;

    if (ctx->hKeyEnc) BCryptDestroyKey(ctx->hKeyEnc);
    if (ctx->hKeyDec) BCryptDestroyKey(ctx->hKeyDec);
    if (ctx->hAlgCipher) BCryptCloseAlgorithmProvider(ctx->hAlgCipher, 0);
    if (ctx->hAlgHmac) BCryptCloseAlgorithmProvider(ctx->hAlgHmac, 0);
    if (ctx->buffer_hmac) {
        pp_zero(ctx->buffer_hmac, HMACMaxLength);
        free(ctx->buffer_hmac);
    }
    zd_free(ctx->hmac_key_enc);
    zd_free(ctx->hmac_key_dec);
    free(ctx);
} 
