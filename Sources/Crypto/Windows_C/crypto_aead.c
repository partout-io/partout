//
//  crypto_aead.c
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
#include "crypto/crypto_aead.h"

#pragma comment(lib, "bcrypt.lib")

// Internal context for AEAD using Windows CNG
typedef struct {
    crypto_t crypto;

    BCRYPT_ALG_HANDLE hAlg;
    BCRYPT_KEY_HANDLE hKeyEnc;
    BCRYPT_KEY_HANDLE hKeyDec;
    size_t cipher_key_len;
    size_t cipher_iv_len;
    size_t tag_len;
    size_t id_len;

    uint8_t *_Nonnull iv_enc;
    uint8_t *_Nonnull iv_dec;
} crypto_aead_ctx;

size_t local_encryption_capacity(const void *vctx, size_t len) {
    const crypto_aead_ctx *ctx = (const crypto_aead_ctx *)vctx;
    assert(ctx);
    return pp_alloc_crypto_capacity(len, ctx->tag_len);
}

static
void local_configure_encrypt(void *vctx,
                             const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    assert(ctx);
    assert(cipher_key && cipher_key->length >= ctx->cipher_key_len);
    assert(hmac_key);

    if (ctx->hKeyEnc) {
        BCryptDestroyKey(ctx->hKeyEnc);
        ctx->hKeyEnc = NULL;
    }
    NTSTATUS status = BCryptGenerateSymmetricKey(
        ctx->hAlg,
        &ctx->hKeyEnc,
        NULL, 0,
        (PUCHAR)cipher_key->bytes,
        (ULONG)ctx->cipher_key_len,
        0
    );
    assert(status == 0);
    memset(ctx->iv_enc, 0, ctx->id_len);
    memcpy(ctx->iv_enc + ctx->id_len, hmac_key->bytes, ctx->cipher_iv_len - ctx->id_len);
}

static
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags, crypto_error_code *error) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    assert(ctx);
    assert(ctx->hKeyEnc);
    assert(flags);
    assert(flags->ad_len >= ctx->id_len);

    ULONG cbResult = 0;
    UCHAR tag[16] = {0};
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO authInfo;
    BCRYPT_INIT_AUTH_MODE_INFO(authInfo);
    memcpy(ctx->iv_enc, flags->iv, (size_t)MIN(flags->iv_len, ctx->cipher_iv_len));
    authInfo.pbNonce = ctx->iv_enc;
    authInfo.cbNonce = (ULONG)ctx->cipher_iv_len;
    authInfo.pbAuthData = (PUCHAR)flags->ad;
    authInfo.cbAuthData = (ULONG)flags->ad_len;
    authInfo.pbTag = tag;
    authInfo.cbTag = (ULONG)ctx->tag_len;

    NTSTATUS status = BCryptEncrypt(
        ctx->hKeyEnc,
        (PUCHAR)in, (ULONG)in_len,
        &authInfo,
        NULL, 0,
        out + ctx->tag_len, (ULONG)(out_buf_len - ctx->tag_len),
        &cbResult,
        0
    );
    if (status != 0) {
        if (error) *error = CryptoErrorEncryption;
        return 0;
    }
    memcpy(out, tag, ctx->tag_len);
    const size_t out_len = ctx->tag_len + cbResult;
    return out_len;
}

static
void local_configure_decrypt(void *vctx,
                             const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    assert(ctx);
    assert(cipher_key && cipher_key->length >= ctx->cipher_key_len);
    assert(hmac_key);

    if (ctx->hKeyDec) {
        BCryptDestroyKey(ctx->hKeyDec);
        ctx->hKeyDec = NULL;
    }
    NTSTATUS status = BCryptGenerateSymmetricKey(
        ctx->hAlg,
        &ctx->hKeyDec,
        NULL, 0,
        (PUCHAR)cipher_key->bytes,
        (ULONG)ctx->cipher_key_len,
        0
    );
    assert(status == 0);
    memset(ctx->iv_dec, 0, ctx->id_len);
    memcpy(ctx->iv_dec + ctx->id_len, hmac_key->bytes, ctx->cipher_iv_len - ctx->id_len);
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags, crypto_error_code *error) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    assert(ctx);
    assert(ctx->hKeyDec);
    assert(flags);
    assert(flags->ad_len >= ctx->id_len);

    ULONG cbResult = 0;
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO authInfo;
    BCRYPT_INIT_AUTH_MODE_INFO(authInfo);
    memcpy(ctx->iv_dec, flags->iv, (size_t)MIN(flags->iv_len, ctx->cipher_iv_len));
    authInfo.pbNonce = ctx->iv_dec;
    authInfo.cbNonce = (ULONG)ctx->cipher_iv_len;
    authInfo.pbAuthData = (PUCHAR)flags->ad;
    authInfo.cbAuthData = (ULONG)flags->ad_len;
    authInfo.pbTag = (PUCHAR)in;
    authInfo.cbTag = (ULONG)ctx->tag_len;

    NTSTATUS status = BCryptDecrypt(
        ctx->hKeyDec,
        (PUCHAR)(in + ctx->tag_len), (ULONG)(in_len - ctx->tag_len),
        &authInfo,
        NULL, 0,
        out, out_buf_len,
        &cbResult,
        0
    );
    if (status != 0) {
        if (error) *error = CryptoErrorEncryption;
        return 0;
    }
    const size_t out_len = cbResult;
    return out_len;
}

// MARK: -

crypto_ctx crypto_aead_create(const char *cipher_name, size_t tag_len, size_t id_len,
                              const crypto_keys_t *keys) {
    assert(cipher_name);

    size_t cipher_key_len;
    if (!_stricmp(cipher_name, "AES-128-GCM")) {
        cipher_key_len = 16;
    } else if (!_stricmp(cipher_name, "AES-256-GCM")) {
        cipher_key_len = 32;
    } else {
        return NULL;
    }

    crypto_aead_ctx *ctx = pp_alloc_crypto(sizeof(crypto_aead_ctx));
    ctx->tag_len = tag_len;
    ctx->id_len = id_len;
    ctx->cipher_key_len = cipher_key_len;
    ctx->cipher_iv_len = 12;  // Standard GCM IV size
    ctx->hAlg = NULL;
    ctx->hKeyEnc = NULL;
    ctx->hKeyDec = NULL;
    ctx->iv_enc = pp_alloc_crypto(ctx->cipher_iv_len);
    ctx->iv_dec = pp_alloc_crypto(ctx->cipher_iv_len);

    NTSTATUS status = BCryptOpenAlgorithmProvider(
        &ctx->hAlg,
        BCRYPT_AES_ALGORITHM,
        NULL,
        0
    );
    assert(status == 0);
    status = BCryptSetProperty(
        ctx->hAlg,
        BCRYPT_CHAINING_MODE,
        (PUCHAR)BCRYPT_CHAIN_MODE_GCM,
        (ULONG)sizeof(BCRYPT_CHAIN_MODE_GCM),
        0
    );
    assert(status == 0);

    ctx->crypto.meta.cipher_key_len = ctx->cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = ctx->cipher_iv_len;
    ctx->crypto.meta.hmac_key_len = 0;
    ctx->crypto.meta.digest_len = 0;
    ctx->crypto.meta.tag_len = tag_len;
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

void crypto_aead_free(crypto_ctx vctx) {
    if (!vctx) return;
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    if (ctx->hKeyEnc) BCryptDestroyKey(ctx->hKeyEnc);
    if (ctx->hKeyDec) BCryptDestroyKey(ctx->hKeyDec);
    if (ctx->hAlg) BCryptCloseAlgorithmProvider(ctx->hAlg, 0);
    pp_zero(ctx->iv_enc, ctx->cipher_iv_len);
    pp_zero(ctx->iv_dec, ctx->cipher_iv_len);
    free(ctx->iv_enc);
    free(ctx->iv_dec);
    free(ctx);
} 
