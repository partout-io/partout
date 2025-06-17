//
//  crypto_cbc.c
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
#include <openssl/rand.h>
#include <string.h>
#include "crypto_openssl/allocation.h"
#include "crypto_openssl/crypto_cbc.h"

#define MAX_HMAC_LENGTH 100

static
size_t crypto_encryption_capacity(const void *vctx, size_t input_len) {
    const crypto_cbc_t *ctx = (crypto_cbc_t *)vctx;
    assert(ctx);
    return pp_alloc_crypto_capacity(input_len, ctx->digest_len + ctx->cipher_iv_len);
}

static
void crypto_configure_encrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_cbc_t *ctx = (crypto_cbc_t *)vctx;
    assert(ctx);
    assert(hmac_key && hmac_key->length >= ctx->hmac_key_len);

    if (ctx->cipher) {
        assert(cipher_key && cipher_key->length >= ctx->cipher_key_len);
        EVP_CIPHER_CTX_reset(ctx->ctx_enc);
        EVP_CipherInit(ctx->ctx_enc, ctx->cipher, cipher_key->bytes, NULL, 1);
    }

    if (ctx->hmac_key_enc) {
        zd_free(ctx->hmac_key_enc);
    }
    ctx->hmac_key_enc = zd_create_copy(hmac_key->bytes, ctx->hmac_key_len);
}

static
bool crypto_encrypt(void *vctx,
                    uint8_t *dst, size_t *dst_len,
                    const uint8_t *in, size_t in_len,
                    const crypto_flags_t *flags, crypto_error_t *error) {
    crypto_cbc_t *ctx = (crypto_cbc_t *)vctx;
    assert(ctx);

    uint8_t *out_iv = dst + ctx->digest_len;
    uint8_t *out_encrypted = out_iv + ctx->cipher_iv_len;
    int l1 = 0, l2 = 0;
    size_t hmac_len = 0;
    int code = 1;

    if (ctx->cipher) {
        if (!flags || !flags->for_testing) {
            if (RAND_bytes(out_iv, (int)ctx->cipher_iv_len) != 1) {
                return false;
            }
        }

        CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherInit(ctx->ctx_enc, NULL, NULL, out_iv, -1);
        CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(ctx->ctx_enc, out_encrypted, &l1, in, (int)in_len);
        CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherFinal_ex(ctx->ctx_enc, out_encrypted + l1, &l2);
    } else {
        assert(out_encrypted == out_iv);
        memcpy(out_encrypted, in, in_len);
        l1 = (int)in_len;
    }

    EVP_MAC_CTX *ossl = EVP_MAC_CTX_new(ctx->mac);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_init(ossl, ctx->hmac_key_enc->bytes, ctx->hmac_key_enc->length, ctx->mac_params);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_update(ossl, out_iv, l1 + l2 + ctx->cipher_iv_len);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_final(ossl, dst, &hmac_len, ctx->digest_len);
    EVP_MAC_CTX_free(ossl);

    *dst_len = l1 + l2 + ctx->cipher_iv_len + ctx->digest_len;

    CRYPTO_OPENSSL_RETURN_STATUS(code, CryptoErrorGeneric)
}

static
void crypto_configure_decrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_cbc_t *ctx = (crypto_cbc_t *)vctx;
    assert(ctx);
    assert(hmac_key && hmac_key->length >= ctx->hmac_key_len);

    if (ctx->cipher) {
        assert(cipher_key && cipher_key->length >= ctx->cipher_key_len);
        EVP_CIPHER_CTX_reset(ctx->ctx_dec);
        EVP_CipherInit(ctx->ctx_dec, ctx->cipher, cipher_key->bytes, NULL, 0);
    }

    if (ctx->hmac_key_dec) {
        zd_free(ctx->hmac_key_dec);
    }
    ctx->hmac_key_dec = zd_create_copy(hmac_key->bytes, ctx->hmac_key_len);
}

static
bool crypto_decrypt(void *vctx,
                    uint8_t *out, size_t *out_len,
                    const uint8_t *in, size_t in_len,
                    const crypto_flags_t *flags, crypto_error_t *error) {
    crypto_cbc_t *ctx = (crypto_cbc_t *)vctx;
    assert(ctx);

    const uint8_t *iv = in + ctx->digest_len;
    const uint8_t *encrypted = in + ctx->digest_len + ctx->cipher_iv_len;
    size_t l1 = 0, l2 = 0;
    int code = 1;

    EVP_MAC_CTX *ossl = EVP_MAC_CTX_new(ctx->mac);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_init(ossl, ctx->hmac_key_dec->bytes, ctx->hmac_key_dec->length, ctx->mac_params);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_update(ossl, in + ctx->digest_len, in_len - ctx->digest_len);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_final(ossl, ctx->buffer_hmac, &l1, ctx->digest_len);
    EVP_MAC_CTX_free(ossl);

    if (CRYPTO_OPENSSL_SUCCESS(code) && CRYPTO_memcmp(ctx->buffer_hmac, in, ctx->digest_len) != 0) {
        CRYPTO_OPENSSL_RETURN_STATUS(code, CryptoErrorHMAC)
    }

    if (ctx->cipher) {
        CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherInit(ctx->ctx_dec, NULL, NULL, iv, -1);
        CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(ctx->ctx_dec, out, (int *)&l1, encrypted, (int)(in_len - ctx->digest_len - ctx->cipher_iv_len));
        CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherFinal_ex(ctx->ctx_dec, out + l1, (int *)&l2);

        *out_len = l1 + l2;
    } else {
        l2 = (int)in_len - l1;
        memcpy(out, in + l1, l2);

        *out_len = l2;
    }

    return true;
}

static
bool crypto_verify(void *vctx, const uint8_t *in, size_t in_len, crypto_error_t *error) {
    crypto_cbc_t *ctx = (crypto_cbc_t *)vctx;
    assert(ctx);

    size_t l1 = 0;
    int code = 1;

    EVP_MAC_CTX *ossl = EVP_MAC_CTX_new(ctx->mac);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_init(ossl, ctx->hmac_key_dec->bytes, ctx->hmac_key_dec->length, ctx->mac_params);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_update(ossl, in + ctx->digest_len, in_len - ctx->digest_len);
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_final(ossl, ctx->buffer_hmac, &l1, ctx->digest_len);
    EVP_MAC_CTX_free(ossl);

    if (CRYPTO_OPENSSL_SUCCESS(code) && CRYPTO_memcmp(ctx->buffer_hmac, in, ctx->digest_len) != 0) {
        CRYPTO_OPENSSL_RETURN_STATUS(code, CryptoErrorHMAC)
    }

    CRYPTO_OPENSSL_RETURN_STATUS(code, CryptoErrorGeneric)
}

// MARK: -

crypto_cbc_t *crypto_cbc_create(const char *cipher_name, const char *digest_name) {
    assert(digest_name);

    const EVP_CIPHER *cipher = NULL;
    if (cipher_name) {
        cipher = EVP_get_cipherbyname(cipher_name);
        if (!cipher) {
            return NULL;
        }
    }
    const EVP_MD *digest = EVP_get_digestbyname(digest_name);
    if (!digest) {
        return NULL;
    }

    crypto_cbc_t *ctx = pp_alloc_crypto(sizeof(crypto_cbc_t));
    if (!ctx) {
        return NULL;
    }

    if (cipher_name) {
        ctx->cipher = cipher;
        ctx->utf_cipher_name = strdup(cipher_name);
        ctx->cipher_key_len = EVP_CIPHER_key_length(ctx->cipher);
        ctx->cipher_iv_len = EVP_CIPHER_iv_length(ctx->cipher);
    }

    ctx->digest = digest;
    ctx->utf_digest_name = strdup(digest_name);
    // as seen in OpenVPN's crypto_openssl.c:md_kt_size()
    ctx->hmac_key_len = EVP_MD_size(ctx->digest);
    ctx->digest_len = ctx->hmac_key_len;

    if (ctx->cipher) {
        ctx->ctx_enc = EVP_CIPHER_CTX_new();
        ctx->ctx_dec = EVP_CIPHER_CTX_new();
    }

    ctx->mac = EVP_MAC_fetch(NULL, "HMAC", NULL);
    ctx->mac_params = pp_alloc_crypto(2 * sizeof(OSSL_PARAM));
    ctx->mac_params[0] = OSSL_PARAM_construct_utf8_string("digest", ctx->utf_digest_name, 0);
    ctx->mac_params[1] = OSSL_PARAM_construct_end();

    ctx->buffer_hmac = pp_alloc_crypto(MAX_HMAC_LENGTH);

    ctx->crypto.meta.cipher_key_len = ctx->cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = ctx->cipher_iv_len;
    ctx->crypto.meta.hmac_key_len = ctx->hmac_key_len;
    ctx->crypto.meta.digest_len = ctx->digest_len;
    ctx->crypto.meta.tag_len = 0;
    ctx->crypto.meta.encryption_capacity = crypto_encryption_capacity;

    ctx->crypto.encrypter.configure = crypto_configure_encrypt;
    ctx->crypto.encrypter.encrypt = crypto_encrypt;
    ctx->crypto.decrypter.configure = crypto_configure_decrypt;
    ctx->crypto.decrypter.decrypt = crypto_decrypt;
    ctx->crypto.decrypter.verify = crypto_verify;

    return ctx;
}

void crypto_cbc_free(crypto_cbc_t *ctx) {
    if (!ctx) return;

    if (ctx->cipher) {
        EVP_CIPHER_CTX_free(ctx->ctx_enc);
        EVP_CIPHER_CTX_free(ctx->ctx_dec);
    }

    EVP_MAC_free(ctx->mac);
    free(ctx->mac_params);
    if (ctx->buffer_hmac) {
        bzero(ctx->buffer_hmac, MAX_HMAC_LENGTH);
        free(ctx->buffer_hmac);
    }

    free(ctx->utf_cipher_name);
    free(ctx->utf_digest_name);
    zd_free(ctx->hmac_key_enc);
    zd_free(ctx->hmac_key_dec);

    free(ctx);
}
