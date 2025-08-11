/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/evp.h>
#include <string.h>
#include "portable/common.h"
#include "crypto/crypto_aead.h"
#include "crypto/macros.h"

typedef struct {
    pp_crypto crypto;

    // cipher
    const EVP_CIPHER *_Nonnull cipher;
    EVP_CIPHER_CTX *_Nonnull ctx_enc;
    EVP_CIPHER_CTX *_Nonnull ctx_dec;
    uint8_t *_Nonnull iv_enc;
    uint8_t *_Nonnull iv_dec;
    size_t id_len;
} pp_crypto_aead_ctx;

static inline
void local_prepare_iv(const void *vctx, uint8_t *_Nonnull iv, const pp_zd *_Nonnull hmac_key) {
    pp_crypto_aead_ctx *ctx = (pp_crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    pp_zero(iv, ctx->id_len);
    memcpy(iv + ctx->id_len, hmac_key->bytes, ctx->crypto.meta.cipher_iv_len - ctx->id_len);
}

size_t local_encryption_capacity(const void *vctx, size_t len) {
    pp_crypto_aead_ctx *ctx = (pp_crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    return pp_alloc_crypto_capacity(len, ctx->crypto.meta.tag_len);
}

static
void local_configure_encrypt(void *vctx,
                             const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_aead_ctx *ctx = (pp_crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    PP_CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_enc))
    PP_CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_enc, ctx->cipher, cipher_key->bytes, NULL, 1))
    local_prepare_iv(ctx, ctx->iv_enc, hmac_key);
}

static
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags,
                     pp_crypto_error_code *error) {
    pp_crypto_aead_ctx *ctx = (pp_crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(ctx->ctx_enc);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);

    EVP_CIPHER_CTX *ossl = ctx->ctx_enc;
    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t tag_len = ctx->crypto.meta.tag_len;
    int aad_len = 0;
    int ciphertext_len = 0;
    int final_len = 0;

    memcpy(ctx->iv_enc, flags->iv, (size_t)MIN(flags->iv_len, cipher_iv_len));

    PP_CRYPTO_CHECK(EVP_CipherInit(ossl, NULL, NULL, ctx->iv_enc, -1))
    PP_CRYPTO_CHECK(EVP_CipherUpdate(ossl, NULL, &aad_len, flags->ad, (int)flags->ad_len))
    PP_CRYPTO_CHECK(EVP_CipherUpdate(ossl, out + tag_len, &ciphertext_len, in, (int)in_len))
    PP_CRYPTO_CHECK(EVP_CipherFinal_ex(ossl, out + tag_len + ciphertext_len, &final_len))
    PP_CRYPTO_CHECK(EVP_CIPHER_CTX_ctrl(ossl, EVP_CTRL_GCM_GET_TAG, (int)tag_len, out))

    const size_t out_len = tag_len + ciphertext_len + final_len;
    return out_len;
}

static
void local_configure_decrypt(void *vctx,
                             const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_aead_ctx *ctx = (pp_crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    PP_CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_dec))
    PP_CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_dec, ctx->cipher, cipher_key->bytes, NULL, 0))
    local_prepare_iv(ctx, ctx->iv_dec, hmac_key);
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags,
                     pp_crypto_error_code *error) {
    pp_crypto_aead_ctx *ctx = (pp_crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(ctx->ctx_dec);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);

    EVP_CIPHER_CTX *ossl = ctx->ctx_dec;
    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t tag_len = ctx->crypto.meta.tag_len;
    int aad_len = 0;
    int plaintext_len = 0;
    int final_len = 0;

    memcpy(ctx->iv_dec, flags->iv, (size_t)MIN(flags->iv_len, cipher_iv_len));

    PP_CRYPTO_CHECK(EVP_CipherInit(ossl, NULL, NULL, ctx->iv_dec, -1))
    PP_CRYPTO_CHECK(EVP_CIPHER_CTX_ctrl(ossl, EVP_CTRL_GCM_SET_TAG, (int)tag_len, (void *)in))
    PP_CRYPTO_CHECK(EVP_CipherUpdate(ossl, NULL, &aad_len, flags->ad, (int)flags->ad_len))
    PP_CRYPTO_CHECK(EVP_CipherUpdate(ossl, out, &plaintext_len, in + tag_len, (int)(in_len - tag_len)))
    PP_CRYPTO_CHECK(EVP_CipherFinal_ex(ossl, out + plaintext_len, &final_len))

    const size_t out_len = plaintext_len + final_len;
    return out_len;
}

// MARK: -

pp_crypto_ctx pp_crypto_aead_create(const char *cipher_name,
                              size_t tag_len, size_t id_len,
                              const pp_crypto_keys *keys) {
    pp_assert(cipher_name);

    pp_crypto_aead_ctx *ctx = pp_alloc_crypto(sizeof(pp_crypto_aead_ctx));
    ctx->cipher = EVP_get_cipherbyname(cipher_name);
    if (!ctx->cipher) {
        goto failure;
    }
    ctx->ctx_enc = EVP_CIPHER_CTX_new();
    if (!ctx->ctx_enc) {
        goto failure;
    }
    ctx->ctx_dec = EVP_CIPHER_CTX_new();
    if (!ctx->ctx_dec) {
        goto failure;
    }

    // no longer fails

    ctx->crypto.meta.cipher_key_len = EVP_CIPHER_key_length(ctx->cipher);
    ctx->crypto.meta.cipher_iv_len = EVP_CIPHER_iv_length(ctx->cipher);
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
    if (ctx->ctx_enc) EVP_CIPHER_CTX_free(ctx->ctx_enc);
    if (ctx->ctx_dec) EVP_CIPHER_CTX_free(ctx->ctx_dec);
    free(ctx);
    return NULL;
}

void pp_crypto_aead_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_aead_ctx *ctx = (pp_crypto_aead_ctx *)vctx;

    EVP_CIPHER_CTX_free(ctx->ctx_enc);
    EVP_CIPHER_CTX_free(ctx->ctx_dec);
    pp_zero(ctx->iv_enc, ctx->crypto.meta.cipher_iv_len);
    pp_zero(ctx->iv_dec, ctx->crypto.meta.cipher_iv_len);
    free(ctx->iv_enc);
    free(ctx->iv_dec);
    free(ctx);
}
