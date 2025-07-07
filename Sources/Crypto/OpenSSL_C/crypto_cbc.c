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
    zeroing_data_t *_Nonnull hmac_key_enc;
    zeroing_data_t *_Nonnull hmac_key_dec;
} crypto_cbc_ctx;

static
size_t local_encryption_capacity(const void *vctx, size_t input_len) {
    const crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    return pp_alloc_crypto_capacity(input_len, ctx->crypto.meta.digest_len + ctx->crypto.meta.cipher_iv_len);
}

static
void local_configure_encrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->cipher) {
        pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
        CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_enc))
        CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_enc, ctx->cipher, cipher_key->bytes, NULL, 1))
    }
    if (ctx->hmac_key_enc) {
        zd_free(ctx->hmac_key_enc);
    }
    ctx->hmac_key_enc = zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags, crypto_error_code *error) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(!ctx->cipher || ctx->ctx_enc);
    pp_assert(ctx->hmac_key_enc);

    // output = [-digest-|-iv-|-payload-]
    uint8_t *out_iv = out + ctx->crypto.meta.digest_len;
    uint8_t *out_encrypted = out_iv + ctx->crypto.meta.cipher_iv_len;
    int ciphertext_len = 0;
    int final_len = 0;
    size_t mac_len = 0;

    if (ctx->cipher) {
        if (!flags || !flags->for_testing) {
            if (RAND_bytes(out_iv, (int)ctx->crypto.meta.cipher_iv_len) != 1) {
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
    CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, out_iv, ciphertext_len + final_len + ctx->crypto.meta.cipher_iv_len))
    CRYPTO_CHECK_MAC(EVP_MAC_final(mac_ctx, out, &mac_len, ctx->crypto.meta.digest_len))
    EVP_MAC_CTX_free(mac_ctx);

    const size_t out_len = ciphertext_len + final_len + ctx->crypto.meta.cipher_iv_len + ctx->crypto.meta.digest_len;
    return out_len;
}

static
void local_configure_decrypt(void *vctx, const zeroing_data_t *cipher_key, const zeroing_data_t *hmac_key) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->cipher) {
        pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
        CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_dec))
        CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_dec, ctx->cipher, cipher_key->bytes, NULL, 0))
    }
    if (ctx->hmac_key_dec) {
        zd_free(ctx->hmac_key_dec);
    }
    ctx->hmac_key_dec = zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const crypto_flags_t *flags, crypto_error_code *error) {
    (void)flags;
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    pp_assert(ctx);
    pp_assert(!ctx->cipher || ctx->ctx_dec);
    pp_assert(ctx->hmac_key_dec);

    const uint8_t *iv = in + ctx->crypto.meta.digest_len;
    const uint8_t *encrypted = in + ctx->crypto.meta.digest_len + ctx->crypto.meta.cipher_iv_len;
    size_t mac_len = 0;

    EVP_MAC_CTX *mac_ctx = EVP_MAC_CTX_new(ctx->mac);
    CRYPTO_CHECK_MAC(EVP_MAC_init(mac_ctx, ctx->hmac_key_dec->bytes, ctx->hmac_key_dec->length, ctx->mac_params))
    CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, in + ctx->crypto.meta.digest_len, in_len - ctx->crypto.meta.digest_len))
    CRYPTO_CHECK_MAC(EVP_MAC_final(mac_ctx, ctx->buffer_hmac, &mac_len, ctx->crypto.meta.digest_len))
    EVP_MAC_CTX_free(mac_ctx);

    pp_assert(mac_len == ctx->crypto.meta.digest_len);
    if (CRYPTO_memcmp(ctx->buffer_hmac, in, mac_len) != 0) {
        CRYPTO_SET_ERROR(CryptoErrorHMAC)
        return 0;
    }

    size_t out_len = 0;
    if (ctx->cipher) {
        size_t plaintext_len = 0;
        size_t final_len = 0;
        CRYPTO_CHECK(EVP_CipherInit(ctx->ctx_dec, NULL, NULL, iv, -1))
        CRYPTO_CHECK(EVP_CipherUpdate(ctx->ctx_dec, out, (int *)&plaintext_len, encrypted, (int)(in_len - mac_len - ctx->crypto.meta.cipher_iv_len)))
        CRYPTO_CHECK(EVP_CipherFinal_ex(ctx->ctx_dec, out + plaintext_len, (int *)&final_len))
        out_len = plaintext_len + final_len;
    } else {
        out_len = in_len - mac_len;
        memcpy(out, in + mac_len, out_len);
    }
    return out_len;
}

static
bool local_verify(void *vctx, const uint8_t *in, size_t in_len, crypto_error_code *error) {
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;
    pp_assert(ctx);

    size_t mac_len = 0;
    EVP_MAC_CTX *mac_ctx = EVP_MAC_CTX_new(ctx->mac);
    CRYPTO_CHECK_MAC(EVP_MAC_init(mac_ctx, ctx->hmac_key_dec->bytes, ctx->hmac_key_dec->length, ctx->mac_params))
    CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, in + ctx->crypto.meta.digest_len, in_len - ctx->crypto.meta.digest_len))
    CRYPTO_CHECK_MAC(EVP_MAC_final(mac_ctx, ctx->buffer_hmac, &mac_len, ctx->crypto.meta.digest_len))
    EVP_MAC_CTX_free(mac_ctx);

    pp_assert(mac_len == ctx->crypto.meta.digest_len);
    if (CRYPTO_memcmp(ctx->buffer_hmac, in, mac_len) != 0) {
        CRYPTO_SET_ERROR(CryptoErrorHMAC)
        return false;
    }
    return true;
}

// MARK: -

crypto_ctx crypto_cbc_create(const char *cipher_name, const char *digest_name,
                             const crypto_keys_t *keys) {
    pp_assert(digest_name);

    crypto_cbc_ctx *ctx = pp_alloc_crypto(sizeof(crypto_cbc_ctx));
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
    // as seen in OpenVPN's crypto_openssl.c:md_kt_size()
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

    return (crypto_ctx)ctx;

failure:
    // cipher and digest (EVP_get_*byname) do not need to be free-ed
    if (ctx->ctx_enc) EVP_CIPHER_CTX_free(ctx->ctx_enc);
    if (ctx->ctx_dec) EVP_CIPHER_CTX_free(ctx->ctx_dec);
    if (ctx->mac) EVP_MAC_free(ctx->mac);
    free(ctx);
    return NULL;
}

void crypto_cbc_free(crypto_ctx vctx) {
    if (!vctx) return;
    crypto_cbc_ctx *ctx = (crypto_cbc_ctx *)vctx;

    if (ctx->hmac_key_enc) zd_free(ctx->hmac_key_enc);
    if (ctx->hmac_key_dec) zd_free(ctx->hmac_key_dec);

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
