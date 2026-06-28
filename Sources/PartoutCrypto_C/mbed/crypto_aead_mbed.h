/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <psa/crypto.h>
#include <stddef.h>
#include "portable/common.h"
#include "crypto/crypto_base.h"
#include "hmac_mbed.h"

#define PP_MBED_AEAD_AES_BLOCK_SIZE (size_t)16
#define PP_MBED_AEAD_GCM_IV_LENGTH (size_t)12

typedef struct {
    pp_crypto crypto;

    pp_zd *cipher_key_enc;
    pp_zd *cipher_key_dec;
    uint8_t *iv_enc;
    uint8_t *iv_dec;
    size_t id_len;
} pp_crypto_aead;

static
void pp_mbed_aead_set_error(pp_crypto_error_code *error, pp_crypto_error_code code) {
    if (error) {
        *error = code;
    }
}

static
void *pp_mbed_aead_alloc(size_t size) {
    return pp_alloc(size ? size : 1);
}

static
bool pp_mbed_aead_ascii_has_prefix(const char *str, const char *prefix) {
    pp_assert(str);
    pp_assert(prefix);

    while (*prefix) {
        if (!*str || pp_mbed_ascii_upper(*str) != pp_mbed_ascii_upper(*prefix)) {
            return false;
        }
        ++str;
        ++prefix;
    }
    return true;
}

static
bool pp_mbed_aead_ascii_has_suffix(const char *str, const char *suffix) {
    pp_assert(str);
    pp_assert(suffix);

    const size_t str_len = strlen(str);
    const size_t suffix_len = strlen(suffix);
    if (str_len < suffix_len) {
        return false;
    }
    return pp_mbed_ascii_equal(str + str_len - suffix_len, suffix);
}

static
bool pp_mbed_aead_aes_key_len_by_name(const char *name, const char *suffix, size_t *key_len) {
    pp_assert(name);
    pp_assert(suffix);
    pp_assert(key_len);

    if (!pp_mbed_aead_ascii_has_suffix(name, suffix)) {
        return false;
    }
    if (pp_mbed_aead_ascii_has_prefix(name, "AES-128-")) {
        *key_len = 16;
        return true;
    }
    if (pp_mbed_aead_ascii_has_prefix(name, "AES-192-")) {
        *key_len = 24;
        return true;
    }
    if (pp_mbed_aead_ascii_has_prefix(name, "AES-256-")) {
        *key_len = 32;
        return true;
    }
    return false;
}

static
bool pp_mbed_aead_crypt(const uint8_t *key_bytes,
                        size_t key_len,
                        psa_key_usage_t usage,
                        const uint8_t *iv,
                        size_t iv_len,
                        const uint8_t *ad,
                        size_t ad_len,
                        const uint8_t *in,
                        size_t in_len,
                        uint8_t *out,
                        size_t out_buf_len,
                        size_t tag_len,
                        size_t *out_len) {
    pp_assert(key_bytes);
    pp_assert(iv);
    pp_assert(out);
    pp_assert(out_len);

    const psa_algorithm_t algorithm = PSA_ALG_AEAD_WITH_SHORTENED_TAG(PSA_ALG_GCM, tag_len);
    mbedtls_svc_key_id_t key = MBEDTLS_SVC_KEY_ID_INIT;
    if (!pp_mbed_import_key(PSA_KEY_TYPE_AES,
                            usage,
                            algorithm,
                            key_bytes,
                            key_len,
                            &key)) {
        return false;
    }

    psa_status_t status;
    if (usage == PSA_KEY_USAGE_ENCRYPT) {
        status = psa_aead_encrypt(key,
                                  algorithm,
                                  iv,
                                  iv_len,
                                  ad_len ? ad : NULL,
                                  ad_len,
                                  in_len ? in : NULL,
                                  in_len,
                                  out,
                                  out_buf_len,
                                  out_len);
    } else {
        status = psa_aead_decrypt(key,
                                  algorithm,
                                  iv,
                                  iv_len,
                                  ad_len ? ad : NULL,
                                  ad_len,
                                  in_len ? in : NULL,
                                  in_len,
                                  out,
                                  out_buf_len,
                                  out_len);
    }

    (void)psa_destroy_key(key);
    return status == PSA_SUCCESS;
}

static
void pp_mbed_aead_prepare_iv(void *vctx, uint8_t *iv, const pp_zd *hmac_key) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->crypto.meta.cipher_iv_len >= ctx->id_len);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.cipher_iv_len - ctx->id_len);
    pp_zero(iv, ctx->id_len);
    memcpy(iv + ctx->id_len, hmac_key->bytes, ctx->crypto.meta.cipher_iv_len - ctx->id_len);
}

static
size_t pp_mbed_aead_encryption_capacity(const void *vctx, size_t len) {
    const pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    return pp_crypto_encryption_base_capacity(len, ctx->crypto.meta.tag_len);
}

static
void pp_mbed_aead_configure_encrypt(void *vctx,
                                    const pp_zd *cipher_key,
                                    const pp_zd *hmac_key) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    if (ctx->cipher_key_enc) {
        pp_zd_free(ctx->cipher_key_enc);
    }
    ctx->cipher_key_enc = pp_zd_create_from_data(cipher_key->bytes, ctx->crypto.meta.cipher_key_len);
    pp_mbed_aead_prepare_iv(ctx, ctx->iv_enc, hmac_key);
}

static
size_t pp_mbed_aead_encrypt(void *vctx,
                            uint8_t *out,
                            size_t out_buf_len,
                            const uint8_t *in,
                            size_t in_len,
                            const pp_crypto_flags *flags,
                            pp_crypto_error_code *error) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->cipher_key_enc);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);
    pp_assert_encryption_length(out_buf_len, in_len);

    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t tag_len = ctx->crypto.meta.tag_len;

    if (flags->iv_len > 0) {
        pp_assert(flags->iv);
        memcpy(ctx->iv_enc, flags->iv, (size_t)MIN(flags->iv_len, cipher_iv_len));
    }

    uint8_t *tmp = pp_mbed_aead_alloc(in_len + tag_len);
    size_t tmp_len = 0;
    const bool ok = pp_mbed_aead_crypt(ctx->cipher_key_enc->bytes,
                                       ctx->cipher_key_enc->length,
                                       PSA_KEY_USAGE_ENCRYPT,
                                       ctx->iv_enc,
                                       cipher_iv_len,
                                       flags->ad,
                                       flags->ad_len,
                                       in,
                                       in_len,
                                       tmp,
                                       in_len + tag_len,
                                       tag_len,
                                       &tmp_len);
    if (!ok || tmp_len != in_len + tag_len) {
        pp_zero(tmp, in_len + tag_len);
        pp_free(tmp);
        pp_mbed_aead_set_error(error, PPCryptoErrorEncryption);
        return 0;
    }

    memcpy(out, tmp + in_len, tag_len);
    memcpy(out + tag_len, tmp, in_len);
    pp_zero(tmp, in_len + tag_len);
    pp_free(tmp);
    return tag_len + in_len;
}

static
void pp_mbed_aead_configure_decrypt(void *vctx,
                                    const pp_zd *cipher_key,
                                    const pp_zd *hmac_key) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    if (ctx->cipher_key_dec) {
        pp_zd_free(ctx->cipher_key_dec);
    }
    ctx->cipher_key_dec = pp_zd_create_from_data(cipher_key->bytes, ctx->crypto.meta.cipher_key_len);
    pp_mbed_aead_prepare_iv(ctx, ctx->iv_dec, hmac_key);
}

static
size_t pp_mbed_aead_decrypt(void *vctx,
                            uint8_t *out,
                            size_t out_buf_len,
                            const uint8_t *in,
                            size_t in_len,
                            const pp_crypto_flags *flags,
                            pp_crypto_error_code *error) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->cipher_key_dec);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);
    pp_assert_decryption_length(out_buf_len, in_len);

    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t tag_len = ctx->crypto.meta.tag_len;
    if (in_len < tag_len) {
        pp_mbed_aead_set_error(error, PPCryptoErrorEncryption);
        return 0;
    }

    if (flags->iv_len > 0) {
        pp_assert(flags->iv);
        memcpy(ctx->iv_dec, flags->iv, (size_t)MIN(flags->iv_len, cipher_iv_len));
    }

    const size_t encrypted_len = in_len - tag_len;
    uint8_t *tmp = pp_mbed_aead_alloc(in_len);
    memcpy(tmp, in + tag_len, encrypted_len);
    memcpy(tmp + encrypted_len, in, tag_len);

    size_t out_len = 0;
    const bool ok = pp_mbed_aead_crypt(ctx->cipher_key_dec->bytes,
                                       ctx->cipher_key_dec->length,
                                       PSA_KEY_USAGE_DECRYPT,
                                       ctx->iv_dec,
                                       cipher_iv_len,
                                       flags->ad,
                                       flags->ad_len,
                                       tmp,
                                       in_len,
                                       out,
                                       out_buf_len,
                                       tag_len,
                                       &out_len);
    pp_zero(tmp, in_len);
    pp_free(tmp);
    if (!ok) {
        pp_mbed_aead_set_error(error, PPCryptoErrorEncryption);
        return 0;
    }
    return out_len;
}

pp_crypto_ctx pp_mbed_crypto_aead_create(const char *cipher_name,
                                         size_t tag_len,
                                         size_t id_len,
                                         const pp_crypto_keys *keys) {
    pp_assert(cipher_name);

    size_t cipher_key_len = 0;
    if (!pp_mbed_aead_aes_key_len_by_name(cipher_name, "GCM", &cipher_key_len)) {
        return NULL;
    }
    if (tag_len > PP_MBED_AEAD_AES_BLOCK_SIZE || id_len > PP_MBED_AEAD_GCM_IV_LENGTH) {
        return NULL;
    }

    pp_crypto_aead *ctx = pp_alloc(sizeof(pp_crypto_aead));

    ctx->crypto.meta.cipher_key_len = cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = PP_MBED_AEAD_GCM_IV_LENGTH;
    ctx->crypto.meta.hmac_key_len = 0;
    ctx->crypto.meta.digest_len = 0;
    ctx->crypto.meta.tag_len = tag_len;
    ctx->crypto.meta.encryption_capacity = pp_mbed_aead_encryption_capacity;

    ctx->iv_enc = pp_alloc(ctx->crypto.meta.cipher_iv_len);
    ctx->iv_dec = pp_alloc(ctx->crypto.meta.cipher_iv_len);
    ctx->id_len = id_len;

    ctx->crypto.encrypter.configure = pp_mbed_aead_configure_encrypt;
    ctx->crypto.encrypter.encrypt = pp_mbed_aead_encrypt;
    ctx->crypto.decrypter.configure = pp_mbed_aead_configure_decrypt;
    ctx->crypto.decrypter.decrypt = pp_mbed_aead_decrypt;
    ctx->crypto.decrypter.verify = NULL;

    if (keys) {
        pp_mbed_aead_configure_encrypt(ctx, keys->cipher.enc_key, keys->hmac.enc_key);
        pp_mbed_aead_configure_decrypt(ctx, keys->cipher.dec_key, keys->hmac.dec_key);
    }

    return (pp_crypto_ctx)ctx;
}

void pp_mbed_crypto_aead_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_aead *ctx = (pp_crypto_aead *)vctx;

    if (ctx->cipher_key_enc) pp_zd_free(ctx->cipher_key_enc);
    if (ctx->cipher_key_dec) pp_zd_free(ctx->cipher_key_dec);
    pp_zero(ctx->iv_enc, ctx->crypto.meta.cipher_iv_len);
    pp_zero(ctx->iv_dec, ctx->crypto.meta.cipher_iv_len);
    pp_free(ctx->iv_enc);
    pp_free(ctx->iv_dec);

    pp_free(ctx);
}
