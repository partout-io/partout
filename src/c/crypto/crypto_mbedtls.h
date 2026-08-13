/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <psa/crypto.h>
#include <stddef.h>
#include "portable/common.h"
#include "crypto/crypto.h"
#include "crypto_mbedtls_api.h"
#include "crypto_aead_mbedtls.h"
#include "hmac_mbedtls.h"

#define PP_MBED_AES_BLOCK_SIZE (size_t)16

static
void pp_mbed_set_error(pp_crypto_error_code *error, pp_crypto_error_code code) {
    if (error) {
        *error = code;
    }
}

static
bool pp_mbed_ascii_has_prefix(const char *str, const char *prefix) {
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
bool pp_mbed_ascii_has_suffix(const char *str, const char *suffix) {
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
bool pp_mbed_aes_key_len_by_name(const char *name, const char *suffix, size_t *key_len) {
    pp_assert(name);
    pp_assert(suffix);
    pp_assert(key_len);

    if (!pp_mbed_ascii_has_suffix(name, suffix)) {
        return false;
    }
    if (pp_mbed_ascii_has_prefix(name, "AES-128-")) {
        *key_len = 16;
        return true;
    }
    if (pp_mbed_ascii_has_prefix(name, "AES-192-")) {
        *key_len = 24;
        return true;
    }
    if (pp_mbed_ascii_has_prefix(name, "AES-256-")) {
        *key_len = 32;
        return true;
    }
    return false;
}

static
bool pp_mbed_secure_equal(const uint8_t *lhs, const uint8_t *rhs, size_t len) {
    uint8_t diff = 0;
    for (size_t i = 0; i < len; ++i) {
        diff |= lhs[i] ^ rhs[i];
    }
    return diff == 0;
}

static
bool pp_mbed_cipher_crypt(const uint8_t *key_bytes,
                          size_t key_len,
                          psa_key_usage_t usage,
                          psa_algorithm_t algorithm,
                          const uint8_t *iv,
                          size_t iv_len,
                          const uint8_t *in,
                          size_t in_len,
                          uint8_t *out,
                          size_t out_buf_len,
                          size_t *out_len) {
    pp_assert(key_bytes);
    pp_assert(iv);
    pp_assert(out);
    pp_assert(out_len);

    mbedtls_svc_key_id_t key = MBEDTLS_SVC_KEY_ID_INIT;
    if (!pp_mbed_import_key(PSA_KEY_TYPE_AES,
                            usage,
                            algorithm,
                            key_bytes,
                            key_len,
                            &key)) {
        return false;
    }

    psa_cipher_operation_t operation = PSA_CIPHER_OPERATION_INIT;
    psa_status_t status;
    if (usage == PSA_KEY_USAGE_ENCRYPT) {
        status = psa_cipher_encrypt_setup(&operation, key, algorithm);
    } else {
        status = psa_cipher_decrypt_setup(&operation, key, algorithm);
    }

    size_t moved = 0;
    size_t final_moved = 0;
    if (status == PSA_SUCCESS) {
        status = psa_cipher_set_iv(&operation, iv, iv_len);
    }
    if (status == PSA_SUCCESS && in_len > 0) {
        pp_assert(in);
        status = psa_cipher_update(&operation, in, in_len, out, out_buf_len, &moved);
    }
    if (status == PSA_SUCCESS) {
        status = psa_cipher_finish(&operation,
                                   out + moved,
                                   out_buf_len - moved,
                                   &final_moved);
    }
    if (status != PSA_SUCCESS) {
        (void)psa_cipher_abort(&operation);
    }
    (void)psa_destroy_key(key);
    if (status != PSA_SUCCESS) {
        return false;
    }

    *out_len = moved + final_moved;
    return true;
}

bool pp_mbed_crypto_init_seed(const uint8_t *src, const size_t len) {
    (void)src;
    (void)len;

    uint8_t probe = 0;
    return pp_mbed_init() &&
           psa_generate_random(&probe, sizeof(probe)) == PSA_SUCCESS;
}

// MARK: - CBC

typedef struct {
    pp_crypto crypto;

    bool has_cipher;
    pp_zd *cipher_key_enc;
    pp_zd *cipher_key_dec;

    pp_mbed_digest digest;
    uint8_t buffer_hmac[PP_MBED_HMAC_MAX_LENGTH];
    pp_zd *hmac_key_enc;
    pp_zd *hmac_key_dec;
} pp_crypto_cbc;

static
size_t pp_mbed_cbc_encryption_capacity(const void *vctx, size_t input_len) {
    const pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    return pp_crypto_encryption_base_capacity(input_len, ctx->crypto.meta.digest_len + ctx->crypto.meta.cipher_iv_len);
}

static
void pp_mbed_cbc_configure_encrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->has_cipher) {
        pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
        if (ctx->cipher_key_enc) {
            pp_zd_free(ctx->cipher_key_enc);
        }
        ctx->cipher_key_enc = pp_zd_create_from_data(cipher_key->bytes, ctx->crypto.meta.cipher_key_len);
    }
    if (ctx->hmac_key_enc) {
        pp_zd_free(ctx->hmac_key_enc);
    }
    ctx->hmac_key_enc = pp_zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t pp_mbed_cbc_encrypt(void *vctx,
                           uint8_t *out,
                           size_t out_buf_len,
                           const uint8_t *in,
                           size_t in_len,
                           const pp_crypto_flags *flags,
                           pp_crypto_error_code *error) {
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    pp_assert(!ctx->has_cipher || ctx->cipher_key_enc);
    pp_assert(ctx->hmac_key_enc);
    pp_assert_encryption_length(out_buf_len, in_len);

    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    uint8_t *out_iv = out + digest_len;
    uint8_t *out_encrypted = out_iv + cipher_iv_len;
    size_t encrypted_len = 0;

    if (ctx->has_cipher) {
        if (!flags || !flags->for_testing) {
            if (!pp_mbed_init() || psa_generate_random(out_iv, cipher_iv_len) != PSA_SUCCESS) {
                pp_mbed_set_error(error, PPCryptoErrorEncryption);
                return 0;
            }
        }
        if (!pp_mbed_cipher_crypt(ctx->cipher_key_enc->bytes,
                                  ctx->cipher_key_enc->length,
                                  PSA_KEY_USAGE_ENCRYPT,
                                  PSA_ALG_CBC_PKCS7,
                                  out_iv,
                                  cipher_iv_len,
                                  in,
                                  in_len,
                                  out_encrypted,
                                  out_buf_len - (size_t)(out_encrypted - out),
                                  &encrypted_len)) {
            pp_mbed_set_error(error, PPCryptoErrorEncryption);
            return 0;
        }
    } else {
        pp_assert(out_encrypted == out_iv);
        memcpy(out_encrypted, in, in_len);
        encrypted_len = in_len;
    }

    if (!pp_mbed_hmac(&ctx->digest,
                      ctx->hmac_key_enc->bytes,
                      ctx->hmac_key_enc->length,
                      out_iv,
                      encrypted_len + cipher_iv_len,
                      NULL,
                      0,
                      out,
                      digest_len)) {
        pp_mbed_set_error(error, PPCryptoErrorHMAC);
        return 0;
    }

    return encrypted_len + cipher_iv_len + digest_len;
}

static
void pp_mbed_cbc_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->has_cipher) {
        pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
        if (ctx->cipher_key_dec) {
            pp_zd_free(ctx->cipher_key_dec);
        }
        ctx->cipher_key_dec = pp_zd_create_from_data(cipher_key->bytes, ctx->crypto.meta.cipher_key_len);
    }
    if (ctx->hmac_key_dec) {
        pp_zd_free(ctx->hmac_key_dec);
    }
    ctx->hmac_key_dec = pp_zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
bool pp_mbed_cbc_verify(void *vctx, const uint8_t *in, size_t in_len, pp_crypto_error_code *error) {
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->hmac_key_dec);

    const size_t digest_len = ctx->crypto.meta.digest_len;
    if (in_len < digest_len) {
        pp_mbed_set_error(error, PPCryptoErrorHMAC);
        return false;
    }

    if (!pp_mbed_hmac(&ctx->digest,
                      ctx->hmac_key_dec->bytes,
                      ctx->hmac_key_dec->length,
                      in + digest_len,
                      in_len - digest_len,
                      NULL,
                      0,
                      ctx->buffer_hmac,
                      sizeof(ctx->buffer_hmac))) {
        pp_mbed_set_error(error, PPCryptoErrorHMAC);
        return false;
    }

    if (!pp_mbed_secure_equal(ctx->buffer_hmac, in, digest_len)) {
        pp_mbed_set_error(error, PPCryptoErrorHMAC);
        return false;
    }
    return true;
}

static
size_t pp_mbed_cbc_decrypt(void *vctx,
                           uint8_t *out,
                           size_t out_buf_len,
                           const uint8_t *in,
                           size_t in_len,
                           const pp_crypto_flags *flags,
                           pp_crypto_error_code *error) {
    (void)flags;
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    pp_assert(!ctx->has_cipher || ctx->cipher_key_dec);
    pp_assert(ctx->hmac_key_dec);
    pp_assert_decryption_length(out_buf_len, in_len);

    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    if (in_len < digest_len + cipher_iv_len) {
        pp_mbed_set_error(error, PPCryptoErrorEncryption);
        return 0;
    }
    if (!pp_mbed_cbc_verify(ctx, in, in_len, error)) {
        return 0;
    }

    const uint8_t *iv = in + digest_len;
    const uint8_t *encrypted = in + digest_len + cipher_iv_len;
    const size_t encrypted_len = in_len - digest_len - cipher_iv_len;
    size_t out_len = 0;

    if (ctx->has_cipher) {
        if (!pp_mbed_cipher_crypt(ctx->cipher_key_dec->bytes,
                                  ctx->cipher_key_dec->length,
                                  PSA_KEY_USAGE_DECRYPT,
                                  PSA_ALG_CBC_PKCS7,
                                  iv,
                                  cipher_iv_len,
                                  encrypted,
                                  encrypted_len,
                                  out,
                                  out_buf_len,
                                  &out_len)) {
            pp_mbed_set_error(error, PPCryptoErrorEncryption);
            return 0;
        }
    } else {
        memcpy(out, in + digest_len, in_len - digest_len);
        out_len = in_len - digest_len;
    }
    return out_len;
}

pp_crypto_ctx pp_mbed_crypto_cbc_create(const char *cipher_name,
                                        const char *digest_name,
                                        const pp_crypto_keys *keys) {
    pp_assert(digest_name);

    size_t cipher_key_len = 0;
    size_t cipher_iv_len = 0;
    if (cipher_name) {
        if (!pp_mbed_aes_key_len_by_name(cipher_name, "CBC", &cipher_key_len)) {
            return NULL;
        }
        cipher_iv_len = PP_MBED_AES_BLOCK_SIZE;
    }

    pp_mbed_digest digest;
    if (!pp_mbed_digest_by_name(digest_name, &digest)) {
        return NULL;
    }

    pp_crypto_cbc *ctx = pp_alloc(sizeof(pp_crypto_cbc));
    ctx->has_cipher = cipher_name != NULL;
    ctx->digest = digest;

    ctx->crypto.meta.cipher_key_len = cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = cipher_iv_len;
    ctx->crypto.meta.hmac_key_len = digest.length;
    ctx->crypto.meta.digest_len = digest.length;
    ctx->crypto.meta.tag_len = 0;
    ctx->crypto.meta.encryption_capacity = pp_mbed_cbc_encryption_capacity;

    ctx->crypto.encrypter.configure = pp_mbed_cbc_configure_encrypt;
    ctx->crypto.encrypter.encrypt = pp_mbed_cbc_encrypt;
    ctx->crypto.decrypter.configure = pp_mbed_cbc_configure_decrypt;
    ctx->crypto.decrypter.decrypt = pp_mbed_cbc_decrypt;
    ctx->crypto.decrypter.verify = pp_mbed_cbc_verify;

    if (keys) {
        pp_mbed_cbc_configure_encrypt(ctx, keys->cipher.enc_key, keys->hmac.enc_key);
        pp_mbed_cbc_configure_decrypt(ctx, keys->cipher.dec_key, keys->hmac.dec_key);
    }

    return (pp_crypto_ctx)ctx;
}

void pp_mbed_crypto_cbc_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_cbc *ctx = (pp_crypto_cbc *)vctx;

    if (ctx->cipher_key_enc) pp_zd_free(ctx->cipher_key_enc);
    if (ctx->cipher_key_dec) pp_zd_free(ctx->cipher_key_dec);
    if (ctx->hmac_key_enc) pp_zd_free(ctx->hmac_key_enc);
    if (ctx->hmac_key_dec) pp_zd_free(ctx->hmac_key_dec);
    pp_zero(ctx->buffer_hmac, PP_MBED_HMAC_MAX_LENGTH);

    pp_free(ctx);
}

// MARK: - CTR

typedef struct {
    pp_crypto crypto;

    pp_zd *cipher_key_enc;
    pp_zd *cipher_key_dec;
    size_t ns_tag_len;
    size_t payload_len;

    pp_mbed_digest digest;
    pp_zd *hmac_key_enc;
    pp_zd *hmac_key_dec;
    uint8_t *buffer_hmac;
} pp_crypto_ctr;

static
size_t pp_mbed_ctr_encryption_capacity(const void *vctx, size_t len) {
    const pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    return pp_crypto_encryption_base_capacity(len, ctx->payload_len + ctx->ns_tag_len);
}

static
void pp_mbed_ctr_configure_encrypt(void *vctx,
                                   const pp_zd *cipher_key,
                                   const pp_zd *hmac_key) {
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);

    if (ctx->cipher_key_enc) {
        pp_zd_free(ctx->cipher_key_enc);
    }
    ctx->cipher_key_enc = pp_zd_create_from_data(cipher_key->bytes, ctx->crypto.meta.cipher_key_len);
    if (ctx->hmac_key_enc) {
        pp_zd_free(ctx->hmac_key_enc);
    }
    ctx->hmac_key_enc = pp_zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
bool pp_mbed_crypt_ctr(uint8_t *out,
                       size_t out_buf_len,
                       const uint8_t *in,
                       size_t in_len,
                       const uint8_t *iv,
                       const pp_zd *cipher_key) {
    size_t moved = 0;
    return pp_mbed_cipher_crypt(cipher_key->bytes,
                                cipher_key->length,
                                PSA_KEY_USAGE_ENCRYPT,
                                PSA_ALG_CTR,
                                iv,
                                PP_MBED_AES_BLOCK_SIZE,
                                in,
                                in_len,
                                out,
                                out_buf_len,
                                &moved) &&
           moved == in_len;
}

static
size_t pp_mbed_ctr_encrypt(void *vctx,
                           uint8_t *out,
                           size_t out_buf_len,
                           const uint8_t *in,
                           size_t in_len,
                           const pp_crypto_flags *flags,
                           pp_crypto_error_code *error) {
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->cipher_key_enc);
    pp_assert(ctx->hmac_key_enc);
    pp_assert(flags);
    pp_assert_encryption_length(out_buf_len, in_len);

    uint8_t *out_encrypted = out + ctx->ns_tag_len;

    if (!pp_mbed_hmac(&ctx->digest,
                      ctx->hmac_key_enc->bytes,
                      ctx->hmac_key_enc->length,
                      flags->ad,
                      flags->ad_len,
                      in,
                      in_len,
                      ctx->buffer_hmac,
                      ctx->digest.length)) {
        pp_mbed_set_error(error, PPCryptoErrorHMAC);
        return 0;
    }
    memcpy(out, ctx->buffer_hmac, ctx->ns_tag_len);

    if (!pp_mbed_crypt_ctr(out_encrypted,
                           out_buf_len - ctx->ns_tag_len,
                           in,
                           in_len,
                           out,
                           ctx->cipher_key_enc)) {
        pp_mbed_set_error(error, PPCryptoErrorEncryption);
        return 0;
    }

    return ctx->ns_tag_len + in_len;
}

static
void pp_mbed_ctr_configure_decrypt(void *vctx,
                                   const pp_zd *cipher_key,
                                   const pp_zd *hmac_key) {
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);

    if (ctx->cipher_key_dec) {
        pp_zd_free(ctx->cipher_key_dec);
    }
    ctx->cipher_key_dec = pp_zd_create_from_data(cipher_key->bytes, ctx->crypto.meta.cipher_key_len);
    if (ctx->hmac_key_dec) {
        pp_zd_free(ctx->hmac_key_dec);
    }
    ctx->hmac_key_dec = pp_zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t pp_mbed_ctr_decrypt(void *vctx,
                           uint8_t *out,
                           size_t out_buf_len,
                           const uint8_t *in,
                           size_t in_len,
                           const pp_crypto_flags *flags,
                           pp_crypto_error_code *error) {
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->cipher_key_dec);
    pp_assert(ctx->hmac_key_dec);
    pp_assert(flags);
    pp_assert_decryption_length(out_buf_len, in_len);

    if (in_len < ctx->ns_tag_len) {
        pp_mbed_set_error(error, PPCryptoErrorEncryption);
        return 0;
    }

    const uint8_t *iv = in;
    const uint8_t *encrypted = in + ctx->ns_tag_len;
    const size_t encrypted_len = in_len - ctx->ns_tag_len;
    if (!pp_mbed_crypt_ctr(out,
                           out_buf_len,
                           encrypted,
                           encrypted_len,
                           iv,
                           ctx->cipher_key_dec)) {
        pp_mbed_set_error(error, PPCryptoErrorEncryption);
        return 0;
    }

    if (!pp_mbed_hmac(&ctx->digest,
                      ctx->hmac_key_dec->bytes,
                      ctx->hmac_key_dec->length,
                      flags->ad,
                      flags->ad_len,
                      out,
                      encrypted_len,
                      ctx->buffer_hmac,
                      ctx->digest.length)) {
        pp_mbed_set_error(error, PPCryptoErrorHMAC);
        return 0;
    }

    if (!pp_mbed_secure_equal(ctx->buffer_hmac, in, ctx->ns_tag_len)) {
        pp_mbed_set_error(error, PPCryptoErrorHMAC);
        return 0;
    }
    return encrypted_len;
}

pp_crypto_ctx pp_mbed_crypto_ctr_create(const char *cipher_name,
                                        const char *digest_name,
                                        size_t tag_len,
                                        size_t payload_len,
                                        const pp_crypto_keys *keys) {
    pp_assert(cipher_name && digest_name);

    size_t cipher_key_len = 0;
    if (!pp_mbed_aes_key_len_by_name(cipher_name, "CTR", &cipher_key_len)) {
        return NULL;
    }

    pp_mbed_digest digest;
    if (!pp_mbed_digest_by_name(digest_name, &digest)) {
        return NULL;
    }
    if (tag_len > digest.length) {
        return NULL;
    }

    pp_crypto_ctr *ctx = pp_alloc(sizeof(pp_crypto_ctr));
    ctx->digest = digest;
    ctx->buffer_hmac = pp_alloc(digest.length);

    ctx->crypto.meta.cipher_key_len = cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = PP_MBED_AES_BLOCK_SIZE;
    ctx->crypto.meta.hmac_key_len = digest.length;
    ctx->crypto.meta.digest_len = tag_len;
    ctx->crypto.meta.tag_len = tag_len;
    ctx->crypto.meta.encryption_capacity = pp_mbed_ctr_encryption_capacity;
    ctx->ns_tag_len = tag_len;
    ctx->payload_len = payload_len;

    ctx->crypto.encrypter.configure = pp_mbed_ctr_configure_encrypt;
    ctx->crypto.encrypter.encrypt = pp_mbed_ctr_encrypt;
    ctx->crypto.decrypter.configure = pp_mbed_ctr_configure_decrypt;
    ctx->crypto.decrypter.decrypt = pp_mbed_ctr_decrypt;
    ctx->crypto.decrypter.verify = NULL;

    if (keys) {
        pp_mbed_ctr_configure_encrypt(ctx, keys->cipher.enc_key, keys->hmac.enc_key);
        pp_mbed_ctr_configure_decrypt(ctx, keys->cipher.dec_key, keys->hmac.dec_key);
    }

    return (pp_crypto_ctx)ctx;
}

void pp_mbed_crypto_ctr_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_ctr *ctx = (pp_crypto_ctr *)vctx;

    if (ctx->cipher_key_enc) pp_zd_free(ctx->cipher_key_enc);
    if (ctx->cipher_key_dec) pp_zd_free(ctx->cipher_key_dec);
    if (ctx->hmac_key_enc) pp_zd_free(ctx->hmac_key_enc);
    if (ctx->hmac_key_dec) pp_zd_free(ctx->hmac_key_dec);
    if (ctx->buffer_hmac) {
        pp_zero(ctx->buffer_hmac, ctx->digest.length);
        pp_free(ctx->buffer_hmac);
    }

    pp_free(ctx);
}
