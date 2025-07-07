//
//  crypto_aead.c
//  Partout
//
//  Created by Davide De Rosa on 6/14/25.
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
#include <openssl/evp.h>
#include <string.h>
#include "crypto/allocation.h"
#include "crypto/crypto_aead.h"
#include "macros.h"

typedef struct {
    crypto_t crypto;

    // cipher
    const EVP_CIPHER *_Nonnull cipher;
    EVP_CIPHER_CTX *_Nonnull ctx_enc;
    EVP_CIPHER_CTX *_Nonnull ctx_dec;
    uint8_t *_Nonnull iv_enc;
    uint8_t *_Nonnull iv_dec;
    size_t id_len;
} crypto_aead_ctx;

static inline
void local_prepare_iv(const void *vctx, uint8_t *_Nonnull iv, const zeroing_data_t *_Nonnull hmac_key) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    bzero(iv, ctx->id_len);
    memcpy(iv + ctx->id_len, hmac_key->bytes, ctx->crypto.meta.cipher_iv_len - ctx->id_len);
}

size_t local_encryption_capacity(const void *vctx, size_t len) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    return pp_alloc_crypto_capacity(len, ctx->crypto.meta.tag_len);
}

static
void local_configure_encrypt(void *vctx,
                             const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_enc))
    CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_enc, ctx->cipher, cipher_key->bytes, NULL, 1))
    local_prepare_iv(ctx, ctx->iv_enc, hmac_key);
}

static
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags,
                     crypto_error_code *error) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(ctx->ctx_enc);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);

    EVP_CIPHER_CTX *ossl = ctx->ctx_enc;
    int l1 = 0, l2 = 0, tmp = 0, code = 1;

    memcpy(ctx->iv_enc, flags->iv, (size_t)MIN(flags->iv_len, ctx->crypto.meta.cipher_iv_len));

    CRYPTO_CHECK(EVP_CipherInit(ossl, NULL, NULL, ctx->iv_enc, -1))
    CRYPTO_CHECK(EVP_CipherUpdate(ossl, NULL, &tmp, flags->ad, (int)flags->ad_len))
    CRYPTO_CHECK(EVP_CipherUpdate(ossl, out + ctx->crypto.meta.tag_len, &l1, in, (int)in_len))
    CRYPTO_CHECK(EVP_CipherFinal_ex(ossl, out + ctx->crypto.meta.tag_len + l1, &l2))
    CRYPTO_CHECK(EVP_CIPHER_CTX_ctrl(ossl, EVP_CTRL_GCM_GET_TAG, (int)ctx->crypto.meta.tag_len, out))

    const size_t out_len = ctx->crypto.meta.tag_len + l1 + l2;
    return out_len;
}

static
void local_configure_decrypt(void *vctx,
                             const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_dec))
    CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_dec, ctx->cipher, cipher_key->bytes, NULL, 0))
    local_prepare_iv(ctx, ctx->iv_dec, hmac_key);
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags,
                     crypto_error_code *error) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(ctx->ctx_dec);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);

    EVP_CIPHER_CTX *ossl = ctx->ctx_dec;
    int l1 = 0, l2 = 0, tmp = 0, code = 1;

    memcpy(ctx->iv_dec, flags->iv, (size_t)MIN(flags->iv_len, ctx->crypto.meta.cipher_iv_len));

    CRYPTO_CHECK(EVP_CipherInit(ossl, NULL, NULL, ctx->iv_dec, -1))
    CRYPTO_CHECK(EVP_CIPHER_CTX_ctrl(ossl, EVP_CTRL_GCM_SET_TAG, (int)ctx->crypto.meta.tag_len, (void *)in))
    CRYPTO_CHECK(EVP_CipherUpdate(ossl, NULL, &tmp, flags->ad, (int)flags->ad_len))
    CRYPTO_CHECK(EVP_CipherUpdate(ossl, out, &l1, in + ctx->crypto.meta.tag_len, (int)(in_len - ctx->crypto.meta.tag_len)))
    CRYPTO_CHECK(EVP_CipherFinal_ex(ossl, out + l1, &l2))

    const size_t out_len = l1 + l2;
    return out_len;
}

// MARK: -

crypto_ctx crypto_aead_create(const char *cipher_name,
                              size_t tag_len, size_t id_len,
                              const crypto_keys_t *keys) {
    pp_assert(cipher_name);

    crypto_aead_ctx *ctx = pp_alloc_crypto(sizeof(crypto_aead_ctx));
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

    ctx->iv_enc = pp_alloc_crypto(ctx->crypto.meta.cipher_iv_len);
    ctx->iv_dec = pp_alloc_crypto(ctx->crypto.meta.cipher_iv_len);

    ctx->crypto.meta.cipher_key_len = EVP_CIPHER_key_length(ctx->cipher);
    ctx->crypto.meta.cipher_iv_len = EVP_CIPHER_iv_length(ctx->cipher);
    ctx->crypto.meta.hmac_key_len = 0;
    ctx->crypto.meta.digest_len = 0;
    ctx->crypto.meta.tag_len = tag_len;
    ctx->crypto.meta.encryption_capacity = local_encryption_capacity;
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

    return (crypto_ctx)ctx;

failure:
    if (ctx->ctx_enc) EVP_CIPHER_CTX_free(ctx->ctx_enc);
    if (ctx->ctx_dec) EVP_CIPHER_CTX_free(ctx->ctx_dec);
    free(ctx);
    return NULL;
}

void crypto_aead_free(crypto_ctx vctx) {
    if (!vctx) return;
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;

    EVP_CIPHER_CTX_free(ctx->ctx_enc);
    EVP_CIPHER_CTX_free(ctx->ctx_dec);
    pp_zero(ctx->iv_enc, ctx->crypto.meta.cipher_iv_len);
    pp_zero(ctx->iv_dec, ctx->crypto.meta.cipher_iv_len);
    free(ctx->iv_enc);
    free(ctx->iv_dec);
    free(ctx);
}
