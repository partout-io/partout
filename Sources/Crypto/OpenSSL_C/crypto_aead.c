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

    const EVP_CIPHER *_Nonnull cipher;
    size_t cipher_key_len;
    size_t cipher_iv_len;
    size_t tag_len;
    size_t id_len;

    EVP_CIPHER_CTX *_Nonnull ctx_enc;
    EVP_CIPHER_CTX *_Nonnull ctx_dec;
    uint8_t *_Nonnull iv_enc;
    uint8_t *_Nonnull iv_dec;
} crypto_aead_ctx;

size_t local_encryption_capacity(const void *vctx, size_t len) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
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

    EVP_CIPHER_CTX_reset(ctx->ctx_enc);
    EVP_CipherInit(ctx->ctx_enc, ctx->cipher, cipher_key->bytes, NULL, 1);

    pp_zero(ctx->iv_enc, ctx->id_len);
    memcpy(ctx->iv_enc + ctx->id_len, hmac_key->bytes, ctx->cipher_iv_len - ctx->id_len);
}

static
bool local_encrypt(void *vctx,
                   uint8_t *out, size_t *out_len,
                   const uint8_t *in, size_t in_len,
                   const crypto_flags_t *flags, crypto_error_code *error) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    assert(ctx);
    assert(ctx->ctx_enc);
    assert(flags);
    assert(flags->ad_len >= ctx->id_len);

    EVP_CIPHER_CTX *ossl = ctx->ctx_enc;
    int l1 = 0, l2 = 0, tmp = 0, code = 1;

    memcpy(ctx->iv_enc, flags->iv, (size_t)MIN(flags->iv_len, ctx->cipher_iv_len));

    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherInit(ossl, NULL, NULL, ctx->iv_enc, -1);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(ossl, NULL, &tmp, flags->ad, (int)flags->ad_len);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(ossl, out + ctx->tag_len, &l1, in, (int)in_len);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherFinal_ex(ossl, out + ctx->tag_len + l1, &l2);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CIPHER_CTX_ctrl(ossl, EVP_CTRL_GCM_GET_TAG, (int)ctx->tag_len, out);

    *out_len = ctx->tag_len + l1 + l2;

    CRYPTO_OPENSSL_RETURN_STATUS(code, CryptoErrorEncryption)
}

static
void local_configure_decrypt(void *vctx,
                             const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    assert(ctx);
    assert(cipher_key && cipher_key->length >= ctx->cipher_key_len);
    assert(hmac_key);

    EVP_CIPHER_CTX_reset(ctx->ctx_dec);
    EVP_CipherInit(ctx->ctx_dec, ctx->cipher, cipher_key->bytes, NULL, 0);

    pp_zero(ctx->iv_dec, ctx->id_len);
    memcpy(ctx->iv_dec + ctx->id_len, hmac_key->bytes, ctx->cipher_iv_len - ctx->id_len);
}

static
bool local_decrypt(void *vctx,
                   uint8_t *out, size_t *out_len,
                   const uint8_t *in, size_t in_len,
                   const crypto_flags_t *flags, crypto_error_code *error) {
    crypto_aead_ctx *ctx = (crypto_aead_ctx *)vctx;
    assert(ctx);
    assert(ctx->ctx_dec);
    assert(flags);
    assert(flags->ad_len >= ctx->id_len);

    EVP_CIPHER_CTX *ossl = ctx->ctx_dec;
    int l1 = 0, l2 = 0, tmp = 0, code = 1;

    memcpy(ctx->iv_dec, flags->iv, (size_t)MIN(flags->iv_len, ctx->cipher_iv_len));

    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherInit(ossl, NULL, NULL, ctx->iv_dec, -1);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CIPHER_CTX_ctrl(ossl, EVP_CTRL_GCM_SET_TAG, (int)ctx->tag_len, (void *)in);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(ossl, NULL, &tmp, flags->ad, (int)flags->ad_len);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(ossl, out, &l1, in + ctx->tag_len, (int)(in_len - ctx->tag_len));
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherFinal_ex(ossl, out + l1, &l2);

    *out_len = l1 + l2;

    CRYPTO_OPENSSL_RETURN_STATUS(code, CryptoErrorEncryption)
}

// MARK: -

crypto_ctx crypto_aead_create(const char *cipher_name, size_t tag_len, size_t id_len,
                              const crypto_keys_t *keys) {
    assert(cipher_name);

    const EVP_CIPHER *cipher = EVP_get_cipherbyname(cipher_name);
    if (!cipher) {
        return NULL;
    }

    crypto_aead_ctx *ctx = pp_alloc_crypto(sizeof(crypto_aead_ctx));
    ctx->cipher = cipher;
    ctx->tag_len = tag_len;
    ctx->id_len = id_len;
    ctx->cipher_key_len = EVP_CIPHER_key_length(cipher);
    ctx->cipher_iv_len = EVP_CIPHER_iv_length(cipher);

    ctx->ctx_enc = EVP_CIPHER_CTX_new();
    ctx->ctx_dec = EVP_CIPHER_CTX_new();
    ctx->iv_enc = pp_alloc_crypto(ctx->cipher_iv_len);
    ctx->iv_dec = pp_alloc_crypto(ctx->cipher_iv_len);

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

    EVP_CIPHER_CTX_free(ctx->ctx_enc);
    EVP_CIPHER_CTX_free(ctx->ctx_dec);

    pp_zero(ctx->iv_enc, ctx->cipher_iv_len);
    pp_zero(ctx->iv_dec, ctx->cipher_iv_len);
    free(ctx->iv_enc);
    free(ctx->iv_dec);
    free(ctx);
}
