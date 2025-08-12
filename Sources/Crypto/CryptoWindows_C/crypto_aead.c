/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <windows.h>
#include <bcrypt.h>
#include <string.h>
#include "portable/common.h"
#include "crypto/crypto_aead.h"
#include "crypto/macros.h"

#pragma comment(lib, "bcrypt.lib")

typedef struct {
    pp_crypto crypto;

    // cipher
    BCRYPT_ALG_HANDLE hAlg;
    BCRYPT_KEY_HANDLE hKeyEnc;
    BCRYPT_KEY_HANDLE hKeyDec;
    uint8_t *_Nonnull iv_enc;
    uint8_t *_Nonnull iv_dec;
    size_t id_len;
    UCHAR tag[128]; // max length
} pp_crypto_aead_ctx;

size_t local_encryption_capacity(const void *vctx, size_t len) {
    const pp_crypto_aead_ctx *ctx = vctx;
    pp_assert(ctx);
    return pp_alloc_crypto_capacity(len, ctx->crypto.meta.tag_len);
}

static
void local_configure_encrypt(void *vctx,
                             const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_aead_ctx *ctx = vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    if (ctx->hKeyEnc) {
        BCryptDestroyKey(ctx->hKeyEnc);
        ctx->hKeyEnc = NULL;
    }
    PP_CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
        ctx->hAlg,
        &ctx->hKeyEnc,
        NULL, 0,
        (PUCHAR)cipher_key->bytes,
        (ULONG)ctx->crypto.meta.cipher_key_len,
        0
    ))
    memset(ctx->iv_enc, 0, ctx->id_len);
    memcpy(ctx->iv_enc + ctx->id_len, hmac_key->bytes, ctx->crypto.meta.cipher_iv_len - ctx->id_len);
}

static
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    pp_crypto_aead_ctx *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->hKeyEnc);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);

    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t tag_len = ctx->crypto.meta.tag_len;
    ULONG cbResult = 0;
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO authInfo;

    BCRYPT_INIT_AUTH_MODE_INFO(authInfo);
    memcpy(ctx->iv_enc, flags->iv, (size_t)MIN(flags->iv_len, cipher_iv_len));
    authInfo.pbNonce = ctx->iv_enc;
    authInfo.cbNonce = (ULONG)cipher_iv_len;
    authInfo.pbAuthData = (PUCHAR)flags->ad;
    authInfo.cbAuthData = (ULONG)flags->ad_len;
    authInfo.pbTag = ctx->tag;
    authInfo.cbTag = (ULONG)tag_len;

    PP_CRYPTO_CHECK(BCryptEncrypt(
        ctx->hKeyEnc,
        (PUCHAR)in, (ULONG)in_len,
        &authInfo,
        NULL, 0,
        out + tag_len,
        (ULONG)(out_buf_len - tag_len),
        &cbResult,
        0
    ))
    memcpy(out, ctx->tag, tag_len);

    const size_t out_len = tag_len + cbResult;
    return out_len;
}

static
void local_configure_decrypt(void *vctx,
                             const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_aead_ctx *ctx = vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    if (ctx->hKeyDec) {
        BCryptDestroyKey(ctx->hKeyDec);
        ctx->hKeyDec = NULL;
    }
    PP_CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
        ctx->hAlg,
        &ctx->hKeyDec,
        NULL, 0,
        (PUCHAR)cipher_key->bytes,
        (ULONG)ctx->crypto.meta.cipher_key_len,
        0
    ))
    memset(ctx->iv_dec, 0, ctx->id_len);
    memcpy(ctx->iv_dec + ctx->id_len, hmac_key->bytes, ctx->crypto.meta.cipher_iv_len - ctx->id_len);
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    pp_crypto_aead_ctx *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->hKeyDec);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);

    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t tag_len = ctx->crypto.meta.tag_len;
    ULONG cbResult = 0;
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO authInfo;

    BCRYPT_INIT_AUTH_MODE_INFO(authInfo);
    memcpy(ctx->iv_dec, flags->iv, (size_t)MIN(flags->iv_len, cipher_iv_len));
    authInfo.pbNonce = ctx->iv_dec;
    authInfo.cbNonce = (ULONG)cipher_iv_len;
    authInfo.pbAuthData = (PUCHAR)flags->ad;
    authInfo.cbAuthData = (ULONG)flags->ad_len;
    authInfo.pbTag = (PUCHAR)in;
    authInfo.cbTag = (ULONG)tag_len;

    PP_CRYPTO_CHECK(BCryptDecrypt(
        ctx->hKeyDec,
        (PUCHAR)(in + tag_len),
        (ULONG)(in_len - tag_len),
        &authInfo,
        NULL, 0,
        out, out_buf_len,
        &cbResult,
        0
    ))

    const size_t out_len = cbResult;
    return out_len;
}

// MARK: -

pp_crypto_ctx pp_crypto_aead_create(const char *cipher_name,
                              size_t tag_len, size_t id_len,
                              const pp_crypto_keys *keys) {
    pp_assert(cipher_name);

    size_t cipher_key_len;
    if (!_stricmp(cipher_name, "AES-128-GCM")) {
        cipher_key_len = 16;
    } else if (!_stricmp(cipher_name, "AES-256-GCM")) {
        cipher_key_len = 32;
    } else {
        return NULL;
    }

    pp_crypto_aead_ctx *ctx = pp_alloc_crypto(sizeof(pp_crypto_aead_ctx));
    PP_CRYPTO_CHECK_CREATE(BCryptOpenAlgorithmProvider(
        &ctx->hAlg,
        BCRYPT_AES_ALGORITHM,
        NULL,
        0
    ));
    PP_CRYPTO_CHECK_CREATE(BCryptSetProperty(
        ctx->hAlg,
        BCRYPT_CHAINING_MODE,
        (PUCHAR)BCRYPT_CHAIN_MODE_GCM,
        (ULONG)sizeof(BCRYPT_CHAIN_MODE_GCM),
        0
    ));

    // no longer fails

    ctx->crypto.meta.cipher_key_len = cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = 12; // standard GCM IV size
    ctx->crypto.meta.hmac_key_len = 0;
    ctx->crypto.meta.digest_len = 0;
    ctx->crypto.meta.tag_len = tag_len;
    ctx->crypto.meta.encryption_capacity = local_encryption_capacity;

    ctx->iv_enc = pp_alloc_crypto(ctx->crypto.meta.cipher_iv_len);
    ctx->iv_dec = pp_alloc_crypto(ctx->crypto.meta.cipher_iv_len);
    ctx->id_len = id_len;

    ctx->crypto.encrypter.configure = local_configure_encrypt;
    ctx->crypto.encrypter.encrypt = local_encrypt;
    ctx->crypto.decrypter.configure = local_configure_decrypt;
    ctx->crypto.decrypter.decrypt = local_decrypt;
    ctx->crypto.decrypter.verify = NULL;

    if (keys) {
        local_configure_encrypt(ctx, keys->cipher.enc_key, keys->hmac.enc_key);
        local_configure_decrypt(ctx, keys->cipher.dec_key, keys->hmac.dec_key);
    }

    return (pp_crypto_ctx)ctx;

failure:
    if (ctx->hAlg) BCryptCloseAlgorithmProvider(ctx->hAlg, 0);
    free(ctx);
    return NULL;
}

void pp_crypto_aead_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_aead_ctx *ctx = (pp_crypto_aead_ctx *)vctx;

    if (ctx->hKeyEnc) BCryptDestroyKey(ctx->hKeyEnc);
    if (ctx->hKeyDec) BCryptDestroyKey(ctx->hKeyDec);
    BCryptCloseAlgorithmProvider(ctx->hAlg, 0);
    pp_zero(ctx->iv_enc, ctx->crypto.meta.cipher_iv_len);
    pp_zero(ctx->iv_dec, ctx->crypto.meta.cipher_iv_len);
    free(ctx->iv_enc);
    free(ctx->iv_dec);

    free(ctx);
} 
