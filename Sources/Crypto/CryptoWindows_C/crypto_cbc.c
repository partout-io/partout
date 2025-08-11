/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <windows.h>
#include <bcrypt.h>
#include <string.h>
#include "portable/common.h"
#include "crypto/crypto_cbc.h"
#include "crypto/macros.h"

#pragma comment(lib, "bcrypt.lib")

#define IVMaxLength (size_t)16
#define HMACMaxLength (size_t)128

typedef struct {
    pp_crypto crypto;

    // cipher
    BCRYPT_ALG_HANDLE hAlgCipher;
    BCRYPT_KEY_HANDLE hKeyEnc;
    BCRYPT_KEY_HANDLE hKeyDec;

    // HMAC
    BCRYPT_ALG_HANDLE hAlgHmac;
    pp_zd *_Nonnull hmac_key_enc;
    pp_zd *_Nonnull hmac_key_dec;
    UCHAR buffer_iv[IVMaxLength];
    UCHAR buffer_hmac[HMACMaxLength];
} pp_crypto_cbc_ctx;

static
size_t local_encryption_capacity(const void *vctx, size_t input_len) {
    const pp_crypto_cbc_ctx *ctx = (const pp_crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    return pp_alloc_crypto_capacity(input_len, ctx->crypto.meta.digest_len + ctx->crypto.meta.cipher_iv_len);
}

static
void local_configure_encrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_cbc_ctx *ctx = (pp_crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->hKeyEnc) {
        BCryptDestroyKey(ctx->hKeyEnc);
        ctx->hKeyEnc = NULL;
    }
    if (ctx->hAlgCipher) {
        PP_CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
            ctx->hAlgCipher,
            &ctx->hKeyEnc,
            NULL, 0,
            (PUCHAR)cipher_key->bytes,
            (ULONG)ctx->crypto.meta.cipher_key_len,
            0
        ))
    }
    if (ctx->hmac_key_enc) {
        pp_zd_free(ctx->hmac_key_enc);
    }
    ctx->hmac_key_enc = pp_zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    pp_crypto_cbc_ctx *ctx = (pp_crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(ctx->hmac_key_enc);

    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t hmac_key_len = ctx->crypto.meta.hmac_key_len;
    uint8_t *out_iv = out + digest_len;
    uint8_t *out_encrypted = out_iv + cipher_iv_len;
    ULONG enc_len = 0;
    size_t hmac_len = 0;

    if (ctx->hAlgCipher) {
        if (!flags || !flags->for_testing) {
            PP_CRYPTO_CHECK(BCryptGenRandom(
                NULL,
                out_iv,
                (ULONG)cipher_iv_len,
                BCRYPT_USE_SYSTEM_PREFERRED_RNG
            ))
        }

        // do NOT use out_iv directly because BCryptEncrypt has side-effect
        memcpy(ctx->buffer_iv, out_iv, cipher_iv_len);

        PP_CRYPTO_CHECK(BCryptEncrypt(
            ctx->hKeyEnc,
            (PUCHAR)in, (ULONG)in_len,
            NULL,
            ctx->buffer_iv, (ULONG)cipher_iv_len,
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
    PP_CRYPTO_CHECK_MAC(BCryptCreateHash(
        ctx->hAlgHmac,
        &hHmac,
        NULL, 0,
        ctx->hmac_key_enc->bytes, (ULONG)hmac_key_len,
        0
    ))
    PP_CRYPTO_CHECK_MAC(BCryptHashData(hHmac, out_iv, (ULONG)(enc_len + cipher_iv_len), 0))
    PP_CRYPTO_CHECK_MAC(BCryptFinishHash(hHmac, out, (ULONG)digest_len, 0))
    BCryptDestroyHash(hHmac);

    const size_t out_len = enc_len + cipher_iv_len + digest_len;
    return out_len;
}

static
void local_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_cbc_ctx *ctx = (pp_crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->hKeyDec) {
        BCryptDestroyKey(ctx->hKeyDec);
        ctx->hKeyDec = NULL;
    }
    if (ctx->hAlgCipher) {
        PP_CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
            ctx->hAlgCipher,
            &ctx->hKeyDec,
            NULL, 0,
            (PUCHAR)cipher_key->bytes,
            (ULONG)ctx->crypto.meta.cipher_key_len,
            0
        ))
    }
    if (ctx->hmac_key_dec) {
        pp_zd_free(ctx->hmac_key_dec);
    }
    ctx->hmac_key_dec = pp_zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    (void)flags;
    pp_crypto_cbc_ctx *ctx = (pp_crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(ctx->hmac_key_dec);

    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t hmac_key_len = ctx->crypto.meta.hmac_key_len;
    const uint8_t *iv = in + digest_len;
    const uint8_t *encrypted = in + digest_len + cipher_iv_len;
    ULONG dec_len = 0;
    size_t hmac_len = 0;

    BCRYPT_HASH_HANDLE hHmac = NULL;
    PP_CRYPTO_CHECK(BCryptCreateHash(
        ctx->hAlgHmac,
        &hHmac,
        NULL, 0,
        ctx->hmac_key_dec->bytes, (ULONG)hmac_key_len,
        0
    ))
    PP_CRYPTO_CHECK(BCryptHashData(hHmac, (PUCHAR)(in + digest_len), (ULONG)(in_len - digest_len), 0))
    PP_CRYPTO_CHECK(BCryptFinishHash(hHmac, ctx->buffer_hmac, (ULONG)digest_len, 0))
    BCryptDestroyHash(hHmac);

    if (memcmp(ctx->buffer_hmac, in, digest_len) != 0) {
        PP_CRYPTO_SET_ERROR(PPCryptoErrorHMAC)
        return 0;
    }

    ULONG out_len = 0;
    if (ctx->hAlgCipher) {
        PP_CRYPTO_CHECK(BCryptDecrypt(
            ctx->hKeyDec,
            (PUCHAR)encrypted, (ULONG)(in_len - digest_len - cipher_iv_len),
            NULL,
            (PUCHAR)iv, (ULONG)cipher_iv_len,
            out, out_buf_len,
            &out_len,
            BCRYPT_BLOCK_PADDING
        ))
    } else {
        memcpy(out, in + digest_len, in_len - digest_len);
        out_len = in_len - digest_len;
    }
    return out_len;
}

static
bool local_verify(void *vctx, const uint8_t *in, size_t in_len, pp_crypto_error_code *error) {
    pp_crypto_cbc_ctx *ctx = (pp_crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    size_t hmac_len = 0;

    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t hmac_key_len = ctx->crypto.meta.hmac_key_len;
    BCRYPT_HASH_HANDLE hHmac = NULL;
    PP_CRYPTO_CHECK_MAC(BCryptCreateHash(
        ctx->hAlgHmac,
        &hHmac,
        NULL, 0,
        ctx->hmac_key_dec->bytes, (ULONG)hmac_key_len,
        0
    ))
    PP_CRYPTO_CHECK_MAC(BCryptHashData(hHmac, (PUCHAR)(in + digest_len), (ULONG)(in_len - digest_len), 0))
    PP_CRYPTO_CHECK_MAC(BCryptFinishHash(hHmac, ctx->buffer_hmac, (ULONG)digest_len, 0))
    BCryptDestroyHash(hHmac);

    if (memcmp(ctx->buffer_hmac, in, digest_len) != 0) {
        PP_CRYPTO_SET_ERROR(PPCryptoErrorHMAC)
        return false;
    }
    return true;
}

// MARK: -

pp_crypto_ctx pp_crypto_cbc_create(const char *cipher_name, const char *digest_name,
                             const pp_crypto_keys *keys) {
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

    pp_crypto_cbc_ctx *ctx = pp_alloc_crypto(sizeof(pp_crypto_cbc_ctx));

    if (cipher_name) {
        PP_CRYPTO_CHECK_CREATE(BCryptOpenAlgorithmProvider(
            &ctx->hAlgCipher,
            BCRYPT_AES_ALGORITHM,
            NULL,
            0
        ));
        PP_CRYPTO_CHECK_CREATE(BCryptSetProperty(
            ctx->hAlgCipher,
            BCRYPT_CHAINING_MODE,
            (PUCHAR)BCRYPT_CHAIN_MODE_CBC,
            (ULONG)sizeof(BCRYPT_CHAIN_MODE_CBC),
            0
        ));
    } else {
        ctx->hAlgCipher = NULL;
    }
    PP_CRYPTO_CHECK_CREATE(BCryptOpenAlgorithmProvider(
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

    return (pp_crypto_ctx)ctx;

failure:
    if (ctx->hAlgCipher) BCryptCloseAlgorithmProvider(ctx->hAlgCipher, 0);
    free(ctx);
    return NULL;
}

void pp_crypto_cbc_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_cbc_ctx *ctx = (pp_crypto_cbc_ctx *)vctx;

    if (ctx->hKeyEnc) BCryptDestroyKey(ctx->hKeyEnc);
    if (ctx->hKeyDec) BCryptDestroyKey(ctx->hKeyDec);
    if (ctx->hAlgCipher) BCryptCloseAlgorithmProvider(ctx->hAlgCipher, 0);

    if (ctx->hmac_key_enc) pp_zd_free(ctx->hmac_key_enc);
    if (ctx->hmac_key_dec) pp_zd_free(ctx->hmac_key_dec);
    BCryptCloseAlgorithmProvider(ctx->hAlgHmac, 0);
    pp_zero(ctx->buffer_iv, sizeof(ctx->buffer_iv));
    pp_zero(ctx->buffer_hmac, sizeof(ctx->buffer_hmac));

    free(ctx);
} 
