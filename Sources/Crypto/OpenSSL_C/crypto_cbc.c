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
#include "crypto/allocation.h"
#include "crypto/crypto_cbc.h"
#include "macros.h"

#define HMACMaxLength (size_t)128

typedef struct {
    crypto_t crypto;

    const EVP_CIPHER *_Nullable cipher;
    const EVP_MD *_Nonnull digest;
    char *_Nullable utf_cipher_name;
    char *_Nonnull utf_digest_name;
    size_t cipher_key_len;
    size_t cipher_iv_len;
    size_t hmac_key_len;
    size_t digest_len;

    EVP_MAC *_Nonnull mac;
    OSSL_PARAM *_Nonnull mac_params;
    EVP_CIPHER_CTX *_Nullable ctx_enc;
    EVP_CIPHER_CTX *_Nullable ctx_dec;
    zeroing_data_t *_Nonnull hmac_key_enc;
    zeroing_data_t *_Nonnull hmac_key_dec;
    uint8_t *_Nonnull buffer_hmac;
} crypto_cbc_ctx;

static
size_t local_encryption_capacity(const void *vctx, size_t input_len) {
    const crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    assert(ctx);
    return pp_alloc_crypto_capacity(input_len, ctx->digest_len + ctx->cipher_iv_len);
}

static
void local_configure_encrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
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
    ctx->hmac_key_enc = zd_create_from_data(hmac_key->bytes, ctx->hmac_key_len);
}

static
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags, crypto_error_code *error) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    assert(ctx);
    assert(!ctx->cipher || ctx->ctx_enc);
    assert(ctx->hmac_key_enc);

    // output = [-digest-|-iv-|-payload-]
    uint8_t *out_iv = out + ctx->digest_len;
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
    CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_MAC_final(ossl, out, &hmac_len, ctx->digest_len);
    EVP_MAC_CTX_free(ossl);

    const size_t out_len = l1 + l2 + ctx->cipher_iv_len + ctx->digest_len;

    CRYPTO_OPENSSL_RETURN_LENGTH(code, out_len, CryptoErrorEncryption)
}

static
void local_configure_decrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
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
    ctx->hmac_key_dec = zd_create_from_data(hmac_key->bytes, ctx->hmac_key_len);
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags, crypto_error_code *error) {
    (void)flags;
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    assert(ctx);
    assert(!ctx->cipher || ctx->ctx_dec);
    assert(ctx->hmac_key_dec);

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

    size_t out_len = 0;
    if (ctx->cipher) {
        CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherInit(ctx->ctx_dec, NULL, NULL, iv, -1);
        CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherUpdate(ctx->ctx_dec, out, (int *)&l1, encrypted, (int)(in_len - ctx->digest_len - ctx->cipher_iv_len));
        CRYPTO_OPENSSL_TRACK_STATUS(code) EVP_CipherFinal_ex(ctx->ctx_dec, out + l1, (int *)&l2);
        out_len = l1 + l2;
    } else {
        l2 = (int)in_len - l1;
        memcpy(out, in + l1, l2);
        out_len = l2;
    }
    CRYPTO_OPENSSL_RETURN_LENGTH(code, out_len, CryptoErrorEncryption)
}

static
bool local_verify(void *vctx, const uint8_t *in, size_t in_len, crypto_error_code *error) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
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

    CRYPTO_OPENSSL_RETURN_STATUS(code, CryptoErrorEncryption)
}

// MARK: -

crypto_ctx crypto_cbc_create(const char *cipher_name, const char *digest_name,
                             const crypto_keys_t *keys) {
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

    crypto_cbc_ctx *ctx = pp_alloc_crypto(sizeof(crypto_cbc_ctx));
    if (!ctx) {
        return NULL;
    }

    if (cipher_name) {
        ctx->cipher = cipher;
        ctx->utf_cipher_name = pp_dup(cipher_name);
        ctx->cipher_key_len = EVP_CIPHER_key_length(ctx->cipher);
        ctx->cipher_iv_len = EVP_CIPHER_iv_length(ctx->cipher);
    }

    ctx->digest = digest;
    ctx->utf_digest_name = pp_dup(digest_name);
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

    ctx->buffer_hmac = pp_alloc_crypto(HMACMaxLength);

    ctx->crypto.meta.cipher_key_len = ctx->cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = ctx->cipher_iv_len;
    ctx->crypto.meta.hmac_key_len = ctx->hmac_key_len;
    ctx->crypto.meta.digest_len = ctx->digest_len;
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

    return (crypto_ctx)ctx;
}

void crypto_cbc_free(crypto_ctx vctx) {
    if (!vctx) return;
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;

    if (ctx->cipher) {
        EVP_CIPHER_CTX_free(ctx->ctx_enc);
        EVP_CIPHER_CTX_free(ctx->ctx_dec);
    }

    EVP_MAC_free(ctx->mac);
    free(ctx->mac_params);
    if (ctx->buffer_hmac) {
        pp_zero(ctx->buffer_hmac, HMACMaxLength);
        free(ctx->buffer_hmac);
    }

    if (ctx->utf_cipher_name) {
        free(ctx->utf_cipher_name);
    }
    free(ctx->utf_digest_name);
    zd_free(ctx->hmac_key_enc);
    zd_free(ctx->hmac_key_dec);

    free(ctx);
}
