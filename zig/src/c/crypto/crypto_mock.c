/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/function_table.h"

#pragma clang assume_nonnull begin

static bool pp_mock_crypto_init_seed(const uint8_t *src,
                                     const size_t len) {
    (void)src;
    (void)len;
    return true;
}

static void pp_mock_crypto_configure(void *vctx,
                                     const pp_zd *_Nullable cipher_key,
                                     const pp_zd *_Nullable hmac_key) {
    (void)vctx;
    (void)cipher_key;
    (void)hmac_key;
}

static size_t pp_mock_crypto_encryption_capacity(const void *vctx,
                                                 size_t len) {
    (void)vctx;
    return len;
}

static size_t pp_mock_crypto_copy(void *vctx,
                                  uint8_t *out,
                                  size_t out_buf_len,
                                  const uint8_t *in,
                                  size_t in_len,
                                  const pp_crypto_flags *_Nullable flags,
                                  pp_crypto_error_code *_Nullable error) {
    (void)vctx;
    (void)flags;

    if (out_buf_len < in_len) {
        if (error) *error = PPCryptoErrorEncryption;
        return 0;
    }
    if (in_len) {
        memcpy(out, in, in_len);
    }
    if (error) *error = PPCryptoErrorNone;
    return in_len;
}

static bool pp_mock_crypto_verify(void *vctx,
                                  const uint8_t *in,
                                  size_t in_len,
                                  pp_crypto_error_code *_Nullable error) {
    (void)vctx;
    (void)in;
    (void)in_len;

    if (error) *error = PPCryptoErrorNone;
    return true;
}

static pp_crypto_ctx pp_mock_crypto_create(size_t tag_len) {
    pp_crypto_ctx ctx = pp_alloc(sizeof(*ctx));
    ctx->base.meta.tag_len = tag_len;
    ctx->base.meta.encryption_capacity = pp_mock_crypto_encryption_capacity;
    ctx->base.encrypter.configure = pp_mock_crypto_configure;
    ctx->base.encrypter.encrypt = pp_mock_crypto_copy;
    ctx->base.decrypter.configure = pp_mock_crypto_configure;
    ctx->base.decrypter.decrypt = pp_mock_crypto_copy;
    ctx->base.decrypter.verify = pp_mock_crypto_verify;
    return ctx;
}

static pp_crypto_ctx pp_mock_crypto_aead_create(const char *cipher_name,
                                                size_t tag_len,
                                                size_t id_len,
                                                const pp_crypto_keys *_Nullable keys) {
    (void)cipher_name;
    (void)id_len;
    (void)keys;
    return pp_mock_crypto_create(tag_len);
}

static void pp_mock_crypto_free(pp_crypto_ctx ctx) {
    pp_free(ctx);
}

static pp_crypto_ctx pp_mock_crypto_cbc_create(const char *_Nullable cipher_name,
                                               const char *digest_name,
                                               const pp_crypto_keys *_Nullable keys) {
    (void)cipher_name;
    (void)digest_name;
    (void)keys;
    return pp_mock_crypto_create(0);
}

static pp_crypto_ctx pp_mock_crypto_ctr_create(const char *cipher_name,
                                               const char *digest_name,
                                               size_t tag_len,
                                               size_t payload_len,
                                               const pp_crypto_keys *_Nullable keys) {
    (void)cipher_name;
    (void)digest_name;
    (void)payload_len;
    (void)keys;
    return pp_mock_crypto_create(tag_len);
}

static size_t pp_mock_hmac_do(pp_hmac_ctx *ctx) {
    (void)ctx;
    return 0;
}

static char *_Nullable pp_mock_key_decrypted_from_path(const char *path,
                                                       const char *passphrase) {
    (void)path;
    (void)passphrase;
    return NULL;
}

static char *_Nullable pp_mock_key_decrypted_from_pem(const char *pem,
                                                      const char *passphrase) {
    (void)pem;
    (void)passphrase;
    return NULL;
}

static pp_tls _Nullable pp_mock_tls_create(const pp_tls_options *opt,
                                           pp_tls_error_code *error) {
    (void)opt;
    if (error) *error = PPTLSErrorNone;
    return NULL;
}

static void pp_mock_tls_free(pp_tls tls) {
    (void)tls;
}

static bool pp_mock_tls_start(pp_tls tls) {
    (void)tls;
    return true;
}

static bool pp_mock_tls_is_connected(pp_tls tls) {
    (void)tls;
    return false;
}

static pp_zd *_Nullable pp_mock_tls_pull_cipher(pp_tls tls,
                                                pp_tls_error_code *_Nullable error) {
    (void)tls;
    if (error) *error = PPTLSErrorNone;
    return NULL;
}

static pp_zd *_Nullable pp_mock_tls_pull_plain(pp_tls tls,
                                               pp_tls_error_code *_Nullable error) {
    (void)tls;
    if (error) *error = PPTLSErrorNone;
    return NULL;
}

static bool pp_mock_tls_put_cipher(pp_tls tls,
                                   const uint8_t *src,
                                   size_t src_len,
                                   pp_tls_error_code *_Nullable error) {
    (void)tls;
    (void)src;
    (void)src_len;
    if (error) *error = PPTLSErrorNone;
    return true;
}

static bool pp_mock_tls_put_plain(pp_tls tls,
                                  const uint8_t *src,
                                  size_t src_len,
                                  pp_tls_error_code *_Nullable error) {
    (void)tls;
    (void)src;
    (void)src_len;
    if (error) *error = PPTLSErrorNone;
    return true;
}

static char *_Nullable pp_mock_tls_ca_md5(const pp_tls tls) {
    (void)tls;
    return NULL;
}

#pragma clang assume_nonnull end

pp_crypto_fnt pp_crypto_fnt_mock(void) {
    pp_crypto_fnt table = {
        .name = "mock",
        .enc = {
            .init_seed = pp_mock_crypto_init_seed,
            .aead_create = pp_mock_crypto_aead_create,
            .aead_free = pp_mock_crypto_free,
            .cbc_create = pp_mock_crypto_cbc_create,
            .cbc_free = pp_mock_crypto_free,
            .ctr_create = pp_mock_crypto_ctr_create,
            .ctr_free = pp_mock_crypto_free
        },
        .hmac_do = pp_mock_hmac_do,
        .key_decrypted_from_path = pp_mock_key_decrypted_from_path,
        .key_decrypted_from_pem = pp_mock_key_decrypted_from_pem,
        .tls = {
            .create = pp_mock_tls_create,
            .free = pp_mock_tls_free,
            .start = pp_mock_tls_start,
            .is_connected = pp_mock_tls_is_connected,
            .pull_cipher = pp_mock_tls_pull_cipher,
            .pull_plain = pp_mock_tls_pull_plain,
            .put_cipher = pp_mock_tls_put_cipher,
            .put_plain = pp_mock_tls_put_plain,
            .ca_md5 = pp_mock_tls_ca_md5
        }
    };
    return table;
}
