//
//  crypto_ctr.c
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
#include "crypto/crypto_ctr.h"

static
size_t crypto_encryption_capacity(const void *vctx, size_t len) {
    const crypto_ctr_t *ctx = (crypto_ctr_t *)vctx;
    assert(ctx);
    return pp_alloc_crypto_capacity(len, ctx->payload_len + ctx->ns_tag_len);
}

static
void crypto_configure_encrypt(void *vctx,
                              const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_ctr_t *ctx = (crypto_ctr_t *)vctx;
    assert(ctx);
    assert(hmac_key && hmac_key->length >= ctx->hmac_key_len);
    assert(cipher_key && cipher_key->length >= ctx->cipher_key_len);

    EVP_CIPHER_CTX_reset(ctx->ctx_enc);
    EVP_CipherInit(ctx->ctx_enc, ctx->cipher, cipher_key->bytes, NULL, 1);

    if (ctx->hmac_key_enc) {
        zd_free(ctx->hmac_key_enc);
    }
    ctx->hmac_key_enc = zd_create_copy(hmac_key->bytes, ctx->hmac_key_len);
}

static
bool crypto_encrypt(void *vctx,
                    uint8_t *out, size_t *out_len,
                    const uint8_t *in, size_t in_len,
                    const crypto_flags_t *flags, crypto_error_code *error) {
    crypto_ctr_t *ctx = (crypto_ctr_t *)vctx;
    assert(ctx);
    assert(ctx->ctx_enc);
    assert(ctx->hmac_key_enc);
    assert(flags);

    uint8_t *out_encrypted = out + ctx->ns_tag_len;
    int l1 = 0, l2 = 0;
    size_t l3 = 0;
    int code = 1;

    EVP_MAC_CTX *ossl = EVP_MAC_CTX_new(ctx->mac);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_init(ossl, ctx->hmac_key_enc->bytes, ctx->hmac_key_enc->length, ctx->mac_params);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_update(ossl, flags->ad, flags->ad_len);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_update(ossl, in, in_len);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_final(ossl, out, &l3, ctx->ns_tag_len);
    EVP_MAC_CTX_free(ossl);

    assert(l3 == ctx->ns_tag_len);

    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherInit(ctx->ctx_enc, NULL, NULL, out, -1);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(ctx->ctx_enc, out_encrypted, &l1, in, (int)in_len);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherFinal_ex(ctx->ctx_enc, out_encrypted + l1, &l2);

    *out_len = ctx->ns_tag_len + l1 + l2;

    CRYPTO_OPENSSL_RETURN_STATUS(code, CryptoErrorGeneric)
}

static
void crypto_configure_decrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_ctr_t *ctx = (crypto_ctr_t *)vctx;
    assert(ctx);
    assert(hmac_key && hmac_key->length >= ctx->hmac_key_len);
    assert(cipher_key && cipher_key->length >= ctx->cipher_key_len);

    EVP_CIPHER_CTX_reset(ctx->ctx_dec);
    EVP_CipherInit(ctx->ctx_dec, ctx->cipher, cipher_key->bytes, NULL, 0);

    if (ctx->hmac_key_dec) {
        zd_free(ctx->hmac_key_dec);
    }
    ctx->hmac_key_dec = zd_create_copy(hmac_key->bytes, ctx->hmac_key_len);
}

static
bool crypto_decrypt(void *vctx,
                    uint8_t *out, size_t *out_len,
                    const uint8_t *in, size_t in_len,
                    const crypto_flags_t *flags, crypto_error_code *error) {
    crypto_ctr_t *ctx = (crypto_ctr_t *)vctx;
    assert(ctx);
    assert(ctx->ctx_dec);
    assert(ctx->hmac_key_dec);
    assert(flags);

    const uint8_t *iv = in;
    const uint8_t *encrypted = in + ctx->ns_tag_len;
    int l1 = 0, l2 = 0;
    size_t l3 = 0;
    int code = 1;

    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherInit(ctx->ctx_dec, NULL, NULL, iv, -1);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(ctx->ctx_dec, out, &l1, encrypted, (int)(in_len - ctx->ns_tag_len));
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherFinal_ex(ctx->ctx_dec, out + l1, &l2);

    *out_len = l1 + l2;

    EVP_MAC_CTX *ossl = EVP_MAC_CTX_new(ctx->mac);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_init(ossl, ctx->hmac_key_dec->bytes, ctx->hmac_key_dec->length, ctx->mac_params);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_update(ossl, flags->ad, flags->ad_len);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_update(ossl, out, *out_len);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_final(ossl, ctx->buffer_hmac, &l3, ctx->ns_tag_len);
    EVP_MAC_CTX_free(ossl);

    assert(l3 == ctx->ns_tag_len);

    if (CRYPTO_OPENSSL_SUCCESS(code) && CRYPTO_memcmp(ctx->buffer_hmac, in, ctx->ns_tag_len) != 0) {
        CRYPTO_OPENSSL_RETURN_STATUS(code, CryptoErrorHMAC)
    }

    CRYPTO_OPENSSL_RETURN_STATUS(code, CryptoErrorGeneric)
}

// MARK: -

crypto_ctr_t *crypto_ctr_create(const char *cipher_name, const char *digest_name,
                                size_t tag_len, size_t payload_len,
                                const crypto_keys_t *keys) {
    assert(cipher_name && digest_name);

    const EVP_CIPHER *cipher = EVP_get_cipherbyname(cipher_name);
    if (!cipher) {
        return NULL;
    }
    const EVP_MD *digest = EVP_get_digestbyname(digest_name);
    if (!digest) {
        return NULL;
    }

    crypto_ctr_t *ctx = pp_alloc_crypto(sizeof(crypto_ctr_t));
    if (!ctx) {
        return NULL;
    }

    ctx->cipher = cipher;
    ctx->utf_cipher_name = pp_dup(cipher_name);
    ctx->cipher_key_len = EVP_CIPHER_key_length(ctx->cipher);
    ctx->cipher_iv_len = EVP_CIPHER_iv_length(ctx->cipher);

    ctx->digest = digest;
    ctx->utf_digest_name = pp_dup(digest_name);
    // as seen in OpenVPN's crypto_openssl.c:md_kt_size()
    ctx->hmac_key_len = EVP_MD_size(ctx->digest);

    ctx->ctx_enc = EVP_CIPHER_CTX_new();
    ctx->ctx_dec = EVP_CIPHER_CTX_new();

    ctx->ns_tag_len = tag_len;
    ctx->payload_len = payload_len;

    ctx->mac = EVP_MAC_fetch(NULL, "HMAC", NULL);
    ctx->mac_params = pp_alloc_crypto(2 * sizeof(OSSL_PARAM));
    ctx->mac_params[0] = OSSL_PARAM_construct_utf8_string("digest", ctx->utf_digest_name, 0);
    ctx->mac_params[1] = OSSL_PARAM_construct_end();

    ctx->buffer_hmac = pp_alloc_crypto(tag_len);

    ctx->crypto.meta.cipher_key_len = ctx->cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = ctx->cipher_iv_len;
    ctx->crypto.meta.hmac_key_len = ctx->hmac_key_len;
    ctx->crypto.meta.digest_len = ctx->ns_tag_len;
    ctx->crypto.meta.tag_len = ctx->ns_tag_len;
    ctx->crypto.meta.encryption_capacity = crypto_encryption_capacity;

    ctx->crypto.encrypter.configure = crypto_configure_encrypt;
    ctx->crypto.encrypter.encrypt = crypto_encrypt;
    ctx->crypto.decrypter.configure = crypto_configure_decrypt;
    ctx->crypto.decrypter.decrypt = crypto_decrypt;
    ctx->crypto.decrypter.verify = NULL;

    if (keys) {
        crypto_configure_encrypt(ctx, keys->cipher.enc_key, keys->hmac.enc_key);
        crypto_configure_decrypt(ctx, keys->cipher.dec_key, keys->hmac.dec_key);
    }

    return ctx;
}

void crypto_ctr_free(crypto_ctr_t *ctx) {
    if (!ctx) return;

    EVP_CIPHER_CTX_free(ctx->ctx_enc);
    EVP_CIPHER_CTX_free(ctx->ctx_dec);

    EVP_MAC_free(ctx->mac);
    free(ctx->mac_params);
    pp_zero(ctx->buffer_hmac, ctx->ns_tag_len);
    free(ctx->buffer_hmac);

    free(ctx->utf_cipher_name);
    free(ctx->utf_digest_name);
    zd_free(ctx->hmac_key_enc);
    zd_free(ctx->hmac_key_dec);

    free(ctx);
}
