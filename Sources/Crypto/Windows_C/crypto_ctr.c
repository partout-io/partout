//
//  crypto_ctr.c
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
#include "crypto/crypto_ctr.h"
#include "macros.h"

#pragma comment(lib, "bcrypt.lib")

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

    size_t ns_tag_len;
    size_t payload_len;

    zeroing_data_t *_Nonnull hmac_key_enc;
    zeroing_data_t *_Nonnull hmac_key_dec;
    uint8_t *_Nonnull buffer_hmac;
} crypto_ctr_ctx;

static inline
void ctr_increment(uint8_t *counter, size_t len) {
    for (int i = (int)len - 1; i >= 0; --i) {
        if (++counter[i] != 0) break;
    }
}

static
size_t local_encryption_capacity(const void *vctx, size_t len) {
    const crypto_ctr_ctx *ctx = (const crypto_ctr_ctx *)vctx;
    pp_assert(ctx);
    return pp_alloc_crypto_capacity(len, ctx->payload_len + ctx->ns_tag_len);
}

static
void local_configure_encrypt(void *vctx,
                             const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_ctr_ctx *ctx = (crypto_ctr_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->hmac_key_len);
    pp_assert(cipher_key && cipher_key->length >= ctx->cipher_key_len);

    if (ctx->hKeyEnc) {
        BCryptDestroyKey(ctx->hKeyEnc);
        ctx->hKeyEnc = NULL;
    }
    NTSTATUS status = BCryptGenerateSymmetricKey(
        ctx->hAlgCipher,
        &ctx->hKeyEnc,
        NULL, 0,
        (PUCHAR)cipher_key->bytes,
        (ULONG)ctx->cipher_key_len,
        0
    );
    pp_assert(CRYPTO_CNG_SUCCESS(status));

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
    crypto_ctr_ctx *ctx = (crypto_ctr_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(ctx->hKeyEnc);
    pp_assert(ctx->hmac_key_enc);
    pp_assert(flags);

    uint8_t *out_encrypted = out + ctx->ns_tag_len;
    size_t block_size = ctx->cipher_iv_len;
    size_t nblocks = (in_len + block_size - 1) / block_size;
    uint8_t counter[32] = {0};
    uint8_t ecb_out[32] = {0};
    size_t offset = 0;
    NTSTATUS status;

    // HMAC (SHA256)
    CRYPTO_CNG_TRACK_STATUS(status) BCryptOpenAlgorithmProvider(
        &ctx->hAlgHmac,
        BCRYPT_SHA256_ALGORITHM,
        NULL,
        BCRYPT_ALG_HANDLE_HMAC_FLAG
    );
    CRYPTO_CNG_TRACK_STATUS(status) BCryptCreateHash(
        ctx->hAlgHmac,
        &ctx->hHmacEnc,
        NULL, 0,
        ctx->hmac_key_enc->bytes, (ULONG)ctx->hmac_key_len,
        0
    );
    CRYPTO_CNG_TRACK_STATUS(status) BCryptHashData(ctx->hHmacEnc, (PUCHAR)flags->ad, (ULONG)flags->ad_len, 0);
    CRYPTO_CNG_TRACK_STATUS(status) BCryptHashData(ctx->hHmacEnc, (PUCHAR)in, (ULONG)in_len, 0);
    CRYPTO_CNG_TRACK_STATUS(status) BCryptFinishHash(ctx->hHmacEnc, out, (ULONG)ctx->ns_tag_len, 0);
    BCryptDestroyHash(ctx->hHmacEnc);
    ctx->hHmacEnc = NULL;
    BCryptCloseAlgorithmProvider(ctx->hAlgHmac, 0);
    CRYPTO_CNG_RETURN_IF_FAILED(status, CryptoErrorEncryption)

    // CTR mode using ECB primitive
    memcpy(counter, out, block_size); // Use tag as IV/counter
    for (size_t b = 0; b < nblocks; ++b) {
        ULONG ecb_len = 0;
        CRYPTO_CNG_TRACK_STATUS(status) BCryptEncrypt(
            ctx->hKeyEnc,
            counter, (ULONG)block_size,
            NULL,
            NULL, 0,
            ecb_out, (ULONG)block_size,
            &ecb_len,
            0
        );
        CRYPTO_CNG_RETURN_IF_FAILED(status, CryptoErrorEncryption)
        size_t chunk = (in_len - offset > block_size) ? block_size : (in_len - offset);
        for (size_t i = 0; i < chunk; ++i) {
            out_encrypted[offset + i] = in[offset + i] ^ ecb_out[i];
        }
        offset += chunk;
        ctr_increment(counter, block_size);
    }
    const size_t out_len = ctx->ns_tag_len + in_len;
    return out_len;
}

static
void local_configure_decrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_ctr_ctx *ctx = (crypto_ctr_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->hmac_key_len);
    pp_assert(cipher_key && cipher_key->length >= ctx->cipher_key_len);

    if (ctx->hKeyDec) {
        BCryptDestroyKey(ctx->hKeyDec);
        ctx->hKeyDec = NULL;
    }
    NTSTATUS status = BCryptGenerateSymmetricKey(
        ctx->hAlgCipher,
        &ctx->hKeyDec,
        NULL, 0,
        (PUCHAR)cipher_key->bytes,
        (ULONG)ctx->cipher_key_len,
        0
    );
    pp_assert(CRYPTO_CNG_SUCCESS(status));

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
    crypto_ctr_ctx *ctx = (crypto_ctr_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(ctx->hKeyDec);
    pp_assert(ctx->hmac_key_dec);
    pp_assert(flags);

    const uint8_t *iv = in;
    const uint8_t *encrypted = in + ctx->ns_tag_len;
    size_t enc_len = in_len - ctx->ns_tag_len;
    size_t block_size = ctx->cipher_iv_len;
    size_t nblocks = (enc_len + block_size - 1) / block_size;
    uint8_t counter[32] = {0};
    uint8_t ecb_out[32] = {0};
    size_t offset = 0;
    NTSTATUS status;

    // CTR mode using ECB primitive
    memcpy(counter, iv, block_size);
    for (size_t b = 0; b < nblocks; ++b) {
        ULONG ecb_len = 0;
        CRYPTO_CNG_TRACK_STATUS(status) BCryptEncrypt(
            ctx->hKeyDec,
            counter, (ULONG)block_size,
            NULL,
            NULL, 0,
            ecb_out, (ULONG)block_size,
            &ecb_len,
            0
        );
        CRYPTO_CNG_RETURN_IF_FAILED(status, CryptoErrorEncryption)
        size_t chunk = (enc_len - offset > block_size) ? block_size : (enc_len - offset);
        for (size_t i = 0; i < chunk; ++i) {
            out[offset + i] = encrypted[offset + i] ^ ecb_out[i];
        }
        offset += chunk;
        ctr_increment(counter, block_size);
    }

    size_t out_len = enc_len;

    // HMAC verify
    CRYPTO_CNG_TRACK_STATUS(status) BCryptOpenAlgorithmProvider(
        &ctx->hAlgHmac,
        BCRYPT_SHA256_ALGORITHM,
        NULL,
        BCRYPT_ALG_HANDLE_HMAC_FLAG
    );
    CRYPTO_CNG_TRACK_STATUS(status) BCryptCreateHash(
        ctx->hAlgHmac,
        &ctx->hHmacDec,
        NULL, 0,
        ctx->hmac_key_dec->bytes, (ULONG)ctx->hmac_key_len,
        0
    );
    CRYPTO_CNG_TRACK_STATUS(status) BCryptHashData(ctx->hHmacDec, (PUCHAR)flags->ad, (ULONG)flags->ad_len, 0);
    CRYPTO_CNG_TRACK_STATUS(status) BCryptHashData(ctx->hHmacDec, out, out_len, 0);
    CRYPTO_CNG_TRACK_STATUS(status) BCryptFinishHash(ctx->hHmacDec, ctx->buffer_hmac, (ULONG)ctx->ns_tag_len, 0);
    BCryptDestroyHash(ctx->hHmacDec);
    ctx->hHmacDec = NULL;
    BCryptCloseAlgorithmProvider(ctx->hAlgHmac, 0);
    CRYPTO_CNG_RETURN_IF_FAILED(status, CryptoErrorEncryption)

    if (memcmp(ctx->buffer_hmac, in, ctx->ns_tag_len) != 0) {
        if (error) *error = CryptoErrorHMAC;
        return 0;
    }
    return out_len;
}

// MARK: -

crypto_ctx crypto_ctr_create(const char *cipher_name, const char *digest_name,
                             size_t tag_len, size_t payload_len,
                             const crypto_keys_t *keys) {
    pp_assert(cipher_name && digest_name);

    // Only AES-CTR and HMAC-SHA256 supported
    if (_stricmp(cipher_name, "AES-128-CTR")) {
        return NULL;
    }
    if (_stricmp(digest_name, "SHA256")) {
        return NULL;
    }

    crypto_ctr_ctx *ctx = pp_alloc_crypto(sizeof(crypto_ctr_ctx));
    if (!ctx) {
        return NULL;
    }

    ctx->cipher_key_len = 16; // AES-128
    ctx->cipher_iv_len = 16;  // AES block size
    ctx->hmac_key_len = 32;   // SHA256 output size

    ctx->ns_tag_len = tag_len;
    ctx->payload_len = payload_len;

    ctx->hKeyEnc = NULL;
    ctx->hKeyDec = NULL;
    ctx->hHmacEnc = NULL;
    ctx->hHmacDec = NULL;
    ctx->buffer_hmac = pp_alloc_crypto(tag_len);

    NTSTATUS status = BCryptOpenAlgorithmProvider(
        &ctx->hAlgCipher,
        BCRYPT_AES_ALGORITHM,
        NULL,
        0
    );
    CRYPTO_CNG_CLOSE_IF_FAILED(status, NULL);
    // No chaining mode set: use ECB for manual CTR

    ctx->crypto.meta.cipher_key_len = ctx->cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = ctx->cipher_iv_len;
    ctx->crypto.meta.hmac_key_len = ctx->hmac_key_len;
    ctx->crypto.meta.digest_len = ctx->ns_tag_len;
    ctx->crypto.meta.tag_len = ctx->ns_tag_len;
    ctx->crypto.meta.encryption_capacity = local_encryption_capacity;

    ctx->crypto.encrypter.configure = local_configure_encrypt;
    ctx->crypto.encrypter.encrypt = local_encrypt;
    ctx->crypto.decrypter.configure = local_configure_decrypt;
    ctx->crypto.decrypter.decrypt = local_decrypt;
    ctx->crypto.decrypter.verify = NULL;

    if (keys) {
        local_configure_encrypt(ctx, keys->cipher.enc_key, keys->hmac.enc_key);
        local_configure_decrypt(ctx, keys->cipher.dec_key, keys->hmac.dec_key);
    }

    return (crypto_ctx)ctx;
}

void crypto_ctr_free(crypto_ctx vctx) {
    if (!vctx) return;
    crypto_ctr_ctx *ctx = (crypto_ctr_ctx *)vctx;

    if (ctx->hKeyEnc) BCryptDestroyKey(ctx->hKeyEnc);
    if (ctx->hKeyDec) BCryptDestroyKey(ctx->hKeyDec);
    if (ctx->hAlgCipher) BCryptCloseAlgorithmProvider(ctx->hAlgCipher, 0);
    if (ctx->buffer_hmac) {
        pp_zero(ctx->buffer_hmac, ctx->ns_tag_len);
        free(ctx->buffer_hmac);
    }
    zd_free(ctx->hmac_key_enc);
    zd_free(ctx->hmac_key_dec);
    free(ctx);
} 
