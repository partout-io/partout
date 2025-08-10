/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/evp.h>
#include <openssl/rand.h>
#include <string.h>
#include "portable/common.h"
#include "crypto/crypto_cbc.h"
#include "macros.h"

#define HMACMaxLength (size_t)128

typedef struct {
    pp_crypto crypto;

    // cipher
    const EVP_CIPHER *_Nullable cipher;
    EVP_CIPHER_CTX *_Nullable ctx_enc;
    EVP_CIPHER_CTX *_Nullable ctx_dec;
    char *_Nullable utf_cipher_name;

    // HMAC
    const EVP_MD *_Nonnull digest;
    char *_Nonnull utf_digest_name;
    EVP_MAC *_Nonnull mac;
    OSSL_PARAM *_Nonnull mac_params;
    uint8_t buffer_hmac[HMACMaxLength];
    pp_zd *_Nonnull hmac_key_enc;
    pp_zd *_Nonnull hmac_key_dec;
} pp_crypto_cbc_ctx;

static
size_t local_encryption_capacity(const void *vctx, size_t input_len) {
    const pp_crypto_cbc_ctx *ctx = (pp_crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    return pp_alloc_crypto_capacity(input_len, ctx->crypto.meta.digest_len + ctx->crypto.meta.cipher_iv_len);
}

static
void local_configure_encrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_cbc_ctx *ctx = (pp_crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->cipher) {
        pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
        CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_enc))
        CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_enc, ctx->cipher, cipher_key->bytes, NULL, 1))
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
    pp_assert(!ctx->cipher || ctx->ctx_enc);
    pp_assert(ctx->hmac_key_enc);

    // output = [-digest-|-iv-|-payload-]
    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    uint8_t *out_iv = out + digest_len;
    uint8_t *out_encrypted = out_iv + cipher_iv_len;
    int ciphertext_len = 0;
    int final_len = 0;
    size_t mac_len = 0;

    if (ctx->cipher) {
        if (!flags || !flags->for_testing) {
            if (RAND_bytes(out_iv, (int)cipher_iv_len) != 1) {
                return false;
            }
        }
        CRYPTO_CHECK(EVP_CipherInit(ctx->ctx_enc, NULL, NULL, out_iv, -1))
        CRYPTO_CHECK(EVP_CipherUpdate(ctx->ctx_enc, out_encrypted, &ciphertext_len, in, (int)in_len))
        CRYPTO_CHECK(EVP_CipherFinal_ex(ctx->ctx_enc, out_encrypted + ciphertext_len, &final_len))
    } else {
        pp_assert(out_encrypted == out_iv);
        memcpy(out_encrypted, in, in_len);
        ciphertext_len = (int)in_len;
    }

    EVP_MAC_CTX *mac_ctx = EVP_MAC_CTX_new(ctx->mac);
    CRYPTO_CHECK_MAC(EVP_MAC_init(mac_ctx, ctx->hmac_key_enc->bytes, ctx->hmac_key_enc->length, ctx->mac_params))
    CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, out_iv, ciphertext_len + final_len + cipher_iv_len))
    CRYPTO_CHECK_MAC(EVP_MAC_final(mac_ctx, out, &mac_len, digest_len))
    EVP_MAC_CTX_free(mac_ctx);

    const size_t out_len = ciphertext_len + final_len + cipher_iv_len + digest_len;
    return out_len;
}

static
void local_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_cbc_ctx *ctx = (pp_crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->cipher) {
        pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
        CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_dec))
        CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_dec, ctx->cipher, cipher_key->bytes, NULL, 0))
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
    pp_assert(!ctx->cipher || ctx->ctx_dec);
    pp_assert(ctx->hmac_key_dec);

    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const uint8_t *iv = in + digest_len;
    const uint8_t *encrypted = in + digest_len + cipher_iv_len;
    size_t mac_len = 0;

    EVP_MAC_CTX *mac_ctx = EVP_MAC_CTX_new(ctx->mac);
    CRYPTO_CHECK_MAC(EVP_MAC_init(mac_ctx, ctx->hmac_key_dec->bytes, ctx->hmac_key_dec->length, ctx->mac_params))
    CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, in + digest_len, in_len - digest_len))
    CRYPTO_CHECK_MAC(EVP_MAC_final(mac_ctx, ctx->buffer_hmac, &mac_len, digest_len))
    EVP_MAC_CTX_free(mac_ctx);

    pp_assert(mac_len == digest_len);
    if (CRYPTO_memcmp(ctx->buffer_hmac, in, mac_len) != 0) {
        CRYPTO_SET_ERROR(PPCryptoErrorHMAC)
        return 0;
    }

    size_t out_len = 0;
    if (ctx->cipher) {
        size_t plaintext_len = 0;
        size_t final_len = 0;
        CRYPTO_CHECK(EVP_CipherInit(ctx->ctx_dec, NULL, NULL, iv, -1))
        CRYPTO_CHECK(EVP_CipherUpdate(ctx->ctx_dec, out, (int *)&plaintext_len, encrypted, (int)(in_len - mac_len - cipher_iv_len)))
        CRYPTO_CHECK(EVP_CipherFinal_ex(ctx->ctx_dec, out + plaintext_len, (int *)&final_len))
        out_len = plaintext_len + final_len;
    } else {
        out_len = in_len - mac_len;
        memcpy(out, in + mac_len, out_len);
    }
    return out_len;
}

static
bool local_verify(void *vctx, const uint8_t *in, size_t in_len, pp_crypto_error_code *error) {
    pp_crypto_cbc_ctx *ctx = (pp_crypto_cbc_ctx *)vctx;
    pp_assert(ctx);

    const size_t digest_len = ctx->crypto.meta.digest_len;
    size_t mac_len = 0;
    EVP_MAC_CTX *mac_ctx = EVP_MAC_CTX_new(ctx->mac);
    CRYPTO_CHECK_MAC(EVP_MAC_init(mac_ctx, ctx->hmac_key_dec->bytes, ctx->hmac_key_dec->length, ctx->mac_params))
    CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, in + digest_len, in_len - digest_len))
    CRYPTO_CHECK_MAC(EVP_MAC_final(mac_ctx, ctx->buffer_hmac, &mac_len, digest_len))
    EVP_MAC_CTX_free(mac_ctx);

    pp_assert(mac_len == digest_len);
    if (CRYPTO_memcmp(ctx->buffer_hmac, in, mac_len) != 0) {
        CRYPTO_SET_ERROR(PPCryptoErrorHMAC)
        return false;
    }
    return true;
}

// MARK: -

pp_crypto_ctx pp_crypto_cbc_create(const char *cipher_name, const char *digest_name,
                             const pp_crypto_keys *keys) {
    pp_assert(digest_name);

    pp_crypto_cbc_ctx *ctx = pp_alloc_crypto(sizeof(pp_crypto_cbc_ctx));
    if (cipher_name) {
        ctx->cipher = EVP_get_cipherbyname(cipher_name);
        if (!ctx->cipher) {
            goto failure;
        }
    }
    ctx->digest = EVP_get_digestbyname(digest_name);
    if (!ctx->digest) {
        goto failure;
    }
    ctx->mac = EVP_MAC_fetch(NULL, "HMAC", NULL);
    if (!ctx->mac) {
        goto failure;
    }
    if (ctx->cipher) {
        ctx->ctx_enc = EVP_CIPHER_CTX_new();
        if (!ctx->ctx_enc) {
            goto failure;
        }
        ctx->ctx_dec = EVP_CIPHER_CTX_new();
        if (!ctx->ctx_dec) {
            goto failure;
        }
    }

    // no longer fails

    if (ctx->cipher) {
        ctx->utf_cipher_name = pp_dup(cipher_name);
    }
    ctx->utf_digest_name = pp_dup(digest_name);

    ctx->mac_params = pp_alloc_crypto(2 * sizeof(OSSL_PARAM));
    ctx->mac_params[0] = OSSL_PARAM_construct_utf8_string("digest", ctx->utf_digest_name, 0);
    ctx->mac_params[1] = OSSL_PARAM_construct_end();

    if (ctx->cipher) {
        ctx->crypto.meta.cipher_key_len = EVP_CIPHER_key_length(ctx->cipher);
        ctx->crypto.meta.cipher_iv_len = EVP_CIPHER_iv_length(ctx->cipher);
    }
    // as seen in OpenVPN's pp_crypto_openssl.c:md_kt_size()
    ctx->crypto.meta.hmac_key_len = EVP_MD_size(ctx->digest);
    ctx->crypto.meta.digest_len = ctx->crypto.meta.hmac_key_len;
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
    // cipher and digest (EVP_get_*byname) do not need to be free-ed
    if (ctx->ctx_enc) EVP_CIPHER_CTX_free(ctx->ctx_enc);
    if (ctx->ctx_dec) EVP_CIPHER_CTX_free(ctx->ctx_dec);
    if (ctx->mac) EVP_MAC_free(ctx->mac);
    free(ctx);
    return NULL;
}

void pp_crypto_cbc_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_cbc_ctx *ctx = (pp_crypto_cbc_ctx *)vctx;

    if (ctx->hmac_key_enc) pp_zd_free(ctx->hmac_key_enc);
    if (ctx->hmac_key_dec) pp_zd_free(ctx->hmac_key_dec);

    if (ctx->cipher) {
        EVP_CIPHER_CTX_free(ctx->ctx_enc);
        EVP_CIPHER_CTX_free(ctx->ctx_dec);
        free(ctx->utf_cipher_name);
    }

    free(ctx->utf_digest_name);
    EVP_MAC_free(ctx->mac);
    free(ctx->mac_params);
    pp_zero(ctx->buffer_hmac, HMACMaxLength);

    free(ctx);
}
