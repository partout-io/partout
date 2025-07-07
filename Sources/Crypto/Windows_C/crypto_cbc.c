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

#include <windows.h>
#include <bcrypt.h>
#include <string.h>
#include "crypto/allocation.h"
#include "crypto/crypto_cbc.h"
#include "macros.h"

#pragma comment(lib, "bcrypt.lib")

#define IVMaxLength (size_t)16
#define HMACMaxLength (size_t)128

typedef struct {
    crypto_t crypto;

    // cipher
    BCRYPT_ALG_HANDLE hAlgCipher;
    BCRYPT_KEY_HANDLE hKeyEnc;
    BCRYPT_KEY_HANDLE hKeyDec;

    // HMAC
    BCRYPT_ALG_HANDLE hAlgHmac;
    zeroing_data_t *_Nonnull hmac_key_enc;
    zeroing_data_t *_Nonnull hmac_key_dec;
    UCHAR buffer_iv[IVMaxLength];
    UCHAR buffer_hmac[HMACMaxLength];
} crypto_cbc_ctx;

static
size_t local_encryption_capacity(const void *vctx, size_t input_len) {
    const crypto_cbc_ctx *ctx = (const crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    return pp_alloc_crypto_capacity(input_len, ctx->crypto.meta.digest_len + ctx->crypto.meta.cipher_iv_len);
}

static
void local_configure_encrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->hKeyEnc) {
        BCryptDestroyKey(ctx->hKeyEnc);
        ctx->hKeyEnc = NULL;
    }
    if (ctx->hAlgCipher) {
        CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
            ctx->hAlgCipher,
            &ctx->hKeyEnc,
            NULL, 0,
            (PUCHAR)cipher_key->bytes,
            (ULONG)ctx->crypto.meta.cipher_key_len,
            0
        ))
    }
    if (ctx->hmac_key_enc) {
        zd_free(ctx->hmac_key_enc);
    }
    ctx->hmac_key_enc = zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags, crypto_error_code *error) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(ctx->hmac_key_enc);

    uint8_t *out_iv = out + ctx->crypto.meta.digest_len;
    uint8_t *out_encrypted = out_iv + ctx->crypto.meta.cipher_iv_len;
    ULONG enc_len = 0;
    size_t hmac_len = 0;

    if (ctx->hAlgCipher) {
        if (!flags || !flags->for_testing) {
            CRYPTO_CHECK(BCryptGenRandom(
                NULL,
                out_iv,
                (ULONG)ctx->crypto.meta.cipher_iv_len,
                BCRYPT_USE_SYSTEM_PREFERRED_RNG
            ))
        }

        // do NOT use out_iv directly because BCryptEncrypt has side-effect
        memcpy(ctx->buffer_iv, out_iv, ctx->crypto.meta.cipher_iv_len);

        CRYPTO_CHECK(BCryptEncrypt(
            ctx->hKeyEnc,
            (PUCHAR)in, (ULONG)in_len,
            NULL,
            ctx->buffer_iv, (ULONG)ctx->crypto.meta.cipher_iv_len,
            out_encrypted, out_buf_len - (out_encrypted - out),
            &enc_len,
            BCRYPT_BLOCK_PADDING
        ))
    } else {
        pp_assert(out_encrypted == out_iv);
        memcpy(out_encrypted, in, in_len);
        enc_len = in_len;
    }

    BCRYPT_HASH_HANDLE hHmac = NULL;
    CRYPTO_CHECK_MAC(BCryptCreateHash(
        ctx->hAlgHmac,
        &hHmac,
        NULL, 0,
        ctx->hmac_key_enc->bytes, (ULONG)ctx->crypto.meta.hmac_key_len,
        0
    ))
    CRYPTO_CHECK_MAC(BCryptHashData(hHmac, out_iv, (ULONG)(enc_len + ctx->crypto.meta.cipher_iv_len), 0))
    CRYPTO_CHECK_MAC(BCryptFinishHash(hHmac, out, (ULONG)ctx->crypto.meta.digest_len, 0))
    BCryptDestroyHash(hHmac);

    const size_t out_len = enc_len + ctx->crypto.meta.cipher_iv_len + ctx->crypto.meta.digest_len;
    return out_len;
}

static
void local_configure_decrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->hKeyDec) {
        BCryptDestroyKey(ctx->hKeyDec);
        ctx->hKeyDec = NULL;
    }
    if (ctx->hAlgCipher) {
        CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
            ctx->hAlgCipher,
            &ctx->hKeyDec,
            NULL, 0,
            (PUCHAR)cipher_key->bytes,
            (ULONG)ctx->crypto.meta.cipher_key_len,
            0
        ))
    }
    if (ctx->hmac_key_dec) {
        zd_free(ctx->hmac_key_dec);
    }
    ctx->hmac_key_dec = zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags, crypto_error_code *error) {
    (void)flags;
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(ctx->hmac_key_dec);

    const uint8_t *iv = in + ctx->crypto.meta.digest_len;
    const uint8_t *encrypted = in + ctx->crypto.meta.digest_len + ctx->crypto.meta.cipher_iv_len;
    ULONG dec_len = 0;
    size_t hmac_len = 0;

    BCRYPT_HASH_HANDLE hHmac = NULL;
    CRYPTO_CHECK(BCryptCreateHash(
        ctx->hAlgHmac,
        &hHmac,
        NULL, 0,
        ctx->hmac_key_dec->bytes, (ULONG)ctx->crypto.meta.hmac_key_len,
        0
    ))
    CRYPTO_CHECK(BCryptHashData(hHmac, (PUCHAR)(in + ctx->crypto.meta.digest_len), (ULONG)(in_len - ctx->crypto.meta.digest_len), 0))
    CRYPTO_CHECK(BCryptFinishHash(hHmac, ctx->buffer_hmac, (ULONG)ctx->crypto.meta.digest_len, 0))
    BCryptDestroyHash(hHmac);

    if (memcmp(ctx->buffer_hmac, in, ctx->crypto.meta.digest_len) != 0) {
        if (error) *error = CryptoErrorHMAC;
        return 0;
    }

    ULONG out_len = 0;
    if (ctx->hAlgCipher) {
        CRYPTO_CHECK(BCryptDecrypt(
            ctx->hKeyDec,
            (PUCHAR)encrypted, (ULONG)(in_len - ctx->crypto.meta.digest_len - ctx->crypto.meta.cipher_iv_len),
            NULL,
            (PUCHAR)iv, (ULONG)ctx->crypto.meta.cipher_iv_len,
            out, out_buf_len,
            &out_len,
            BCRYPT_BLOCK_PADDING
        ))
    } else {
        memcpy(out, in + ctx->crypto.meta.digest_len, in_len - ctx->crypto.meta.digest_len);
        out_len = in_len - ctx->crypto.meta.digest_len;
    }
    return out_len;
}

static
bool local_verify(void *vctx, const uint8_t *in, size_t in_len, crypto_error_code *error) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    size_t hmac_len = 0;

    BCRYPT_HASH_HANDLE hHmac = NULL;
    CRYPTO_CHECK_MAC(BCryptCreateHash(
        ctx->hAlgHmac,
        &hHmac,
        NULL, 0,
        ctx->hmac_key_dec->bytes, (ULONG)ctx->crypto.meta.hmac_key_len,
        0
    ))
    CRYPTO_CHECK_MAC(BCryptHashData(hHmac, (PUCHAR)(in + ctx->crypto.meta.digest_len), (ULONG)(in_len - ctx->crypto.meta.digest_len), 0))
    CRYPTO_CHECK_MAC(BCryptFinishHash(hHmac, ctx->buffer_hmac, (ULONG)ctx->crypto.meta.digest_len, 0))
    BCryptDestroyHash(hHmac);

    if (memcmp(ctx->buffer_hmac, in, ctx->crypto.meta.digest_len) != 0) {
        if (error) *error = CryptoErrorHMAC;
        return false;
    }
    return true;
}

// MARK: -

crypto_ctx crypto_cbc_create(const char *cipher_name, const char *digest_name,
                             const crypto_keys_t *keys) {
    pp_assert(digest_name);

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

    if (cipher_name) {
        CRYPTO_CHECK_CREATE(BCryptOpenAlgorithmProvider(
            &ctx->hAlgCipher,
            BCRYPT_AES_ALGORITHM,
            NULL,
            0
        ));
        CRYPTO_CHECK_CREATE(BCryptSetProperty(
            ctx->hAlgCipher,
            BCRYPT_CHAINING_MODE,
            (PUCHAR)BCRYPT_CHAIN_MODE_CBC,
            (ULONG)sizeof(BCRYPT_CHAIN_MODE_CBC),
            0
        ));
    } else {
        ctx->hAlgCipher = NULL;
    }
    CRYPTO_CHECK_CREATE(BCryptOpenAlgorithmProvider(
        &ctx->hAlgHmac,
        hmac_alg_id,
        NULL,
        BCRYPT_ALG_HANDLE_HMAC_FLAG
    ));

    // no longer fails

    ctx->crypto.meta.cipher_key_len = cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = cipher_iv_len;
    ctx->crypto.meta.hmac_key_len = hmac_key_len;
    ctx->crypto.meta.digest_len = hmac_key_len;
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

failure:
    if (ctx->hAlgCipher) BCryptCloseAlgorithmProvider(ctx->hAlgCipher, 0);
    free(ctx);
    return NULL;
}

void crypto_cbc_free(crypto_ctx vctx) {
    if (!vctx) return;
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;

    if (ctx->hKeyEnc) BCryptDestroyKey(ctx->hKeyEnc);
    if (ctx->hKeyDec) BCryptDestroyKey(ctx->hKeyDec);
    if (ctx->hAlgCipher) BCryptCloseAlgorithmProvider(ctx->hAlgCipher, 0);

    if (ctx->hmac_key_enc) zd_free(ctx->hmac_key_enc);
    if (ctx->hmac_key_dec) zd_free(ctx->hmac_key_dec);
    BCryptCloseAlgorithmProvider(ctx->hAlgHmac, 0);
    pp_zero(ctx->buffer_iv, sizeof(ctx->buffer_iv));
    pp_zero(ctx->buffer_hmac, sizeof(ctx->buffer_hmac));

    free(ctx);
} 
