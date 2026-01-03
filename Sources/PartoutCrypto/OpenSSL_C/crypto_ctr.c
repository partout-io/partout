/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/evp.h>
#include <string.h>
#include "portable/common.h"
#include "crypto/crypto_ctr.h"
#include "crypto/macros.h"

typedef struct {
    pp_crypto crypto;

    // cipher
    const EVP_CIPHER *_Nonnull cipher;
    EVP_CIPHER_CTX *_Nonnull ctx_enc;
    EVP_CIPHER_CTX *_Nonnull ctx_dec;
    char *_Nonnull utf_cipher_name;
    size_t ns_tag_len;
    size_t payload_len;

    // HMAC
    const EVP_MD *_Nonnull digest;
    char *_Nonnull utf_digest_name;
    EVP_MAC *_Nonnull mac;
    OSSL_PARAM *_Nonnull mac_params;
    pp_zd *_Nonnull hmac_key_enc;
    pp_zd *_Nonnull hmac_key_dec;
    uint8_t *_Nonnull buffer_hmac;
} pp_crypto_ctr;

static
size_t local_encryption_capacity(const void *vctx, size_t len) {
    const pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    return pp_crypto_encryption_base_capacity(len, ctx->payload_len + ctx->ns_tag_len);
}

static
void local_configure_encrypt(void *vctx,
                             const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);

    PP_CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_enc))
    PP_CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_enc, ctx->cipher, cipher_key->bytes, NULL, 1))
    if (ctx->hmac_key_enc) {
        pp_zd_free(ctx->hmac_key_enc);
    }
    ctx->hmac_key_enc = pp_zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->ctx_enc);
    pp_assert(ctx->hmac_key_enc);
    pp_assert(flags);
    pp_assert_encryption_length(out_buf_len, in_len);

    uint8_t *out_encrypted = out + ctx->ns_tag_len;
    size_t mac_len = 0;

    EVP_MAC_CTX *mac_ctx = EVP_MAC_CTX_new(ctx->mac);
    PP_CRYPTO_CHECK_MAC(EVP_MAC_init(mac_ctx, ctx->hmac_key_enc->bytes, ctx->hmac_key_enc->length, ctx->mac_params))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, flags->ad, flags->ad_len))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, in, in_len))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_final(mac_ctx, out, &mac_len, ctx->ns_tag_len))
    EVP_MAC_CTX_free(mac_ctx);

    pp_assert(mac_len == ctx->ns_tag_len);

    int ciphertext_len = 0;
    int final_len = 0;
    PP_CRYPTO_CHECK(EVP_CipherInit(ctx->ctx_enc, NULL, NULL, out, -1))
    PP_CRYPTO_CHECK(EVP_CipherUpdate(ctx->ctx_enc, out_encrypted, &ciphertext_len, in, (int)in_len))
    PP_CRYPTO_CHECK(EVP_CipherFinal_ex(ctx->ctx_enc, out_encrypted + ciphertext_len, &final_len))

    const size_t out_len = ctx->ns_tag_len + ciphertext_len + final_len;
    return out_len;
}

static
void local_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);

    PP_CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_dec))
    PP_CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_dec, ctx->cipher, cipher_key->bytes, NULL, 0))
    if (ctx->hmac_key_dec) {
        pp_zd_free(ctx->hmac_key_dec);
    }
    ctx->hmac_key_dec = pp_zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->ctx_dec);
    pp_assert(ctx->hmac_key_dec);
    pp_assert(flags);
    pp_assert_decryption_length(out_buf_len, in_len);

    const uint8_t *iv = in;
    const uint8_t *encrypted = in + ctx->ns_tag_len;
    int plaintext_len = 0;
    int final_len = 0;
    size_t mac_len = 0;

    PP_CRYPTO_CHECK(EVP_CipherInit(ctx->ctx_dec, NULL, NULL, iv, -1))
    PP_CRYPTO_CHECK(EVP_CipherUpdate(ctx->ctx_dec, out, &plaintext_len, encrypted, (int)(in_len - ctx->ns_tag_len)))
    PP_CRYPTO_CHECK(EVP_CipherFinal_ex(ctx->ctx_dec, out + plaintext_len, &final_len))
    const size_t out_len = plaintext_len + final_len;

    EVP_MAC_CTX *mac_ctx = EVP_MAC_CTX_new(ctx->mac);
    PP_CRYPTO_CHECK_MAC(EVP_MAC_init(mac_ctx, ctx->hmac_key_dec->bytes, ctx->hmac_key_dec->length, ctx->mac_params))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, flags->ad, flags->ad_len))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, out, out_len))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_final(mac_ctx, ctx->buffer_hmac, &mac_len, ctx->ns_tag_len))
    EVP_MAC_CTX_free(mac_ctx);

    pp_assert(mac_len == ctx->ns_tag_len);
    if (CRYPTO_memcmp(ctx->buffer_hmac, in, ctx->ns_tag_len) != 0) {
        PP_CRYPTO_SET_ERROR(PPCryptoErrorHMAC)
        return 0;
    }
    return out_len;
}

// MARK: -

pp_crypto_ctx pp_crypto_ctr_create(const char *cipher_name, const char *digest_name,
                             size_t tag_len, size_t payload_len,
                             const pp_crypto_keys *keys) {
    pp_assert(cipher_name && digest_name);

    pp_crypto_ctr *ctx = pp_alloc(sizeof(pp_crypto_ctr));

    ctx->cipher = EVP_get_cipherbyname(cipher_name);
    if (!ctx->cipher) {
        goto failure;
    }
    ctx->digest = EVP_get_digestbyname(digest_name);
    if (!ctx->digest) {
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
    ctx->mac = EVP_MAC_fetch(NULL, "HMAC", NULL);
    if (!ctx->mac) {
        goto failure;
    }

    // no longer fails

    ctx->utf_cipher_name = pp_dup(cipher_name);
    ctx->utf_digest_name = pp_dup(digest_name);

    ctx->mac_params = pp_alloc(2 * sizeof(OSSL_PARAM));
    ctx->mac_params[0] = OSSL_PARAM_construct_utf8_string("digest", ctx->utf_digest_name, 0);
    ctx->mac_params[1] = OSSL_PARAM_construct_end();
    ctx->buffer_hmac = pp_alloc(tag_len);

    ctx->crypto.meta.cipher_key_len = EVP_CIPHER_key_length(ctx->cipher);
    ctx->crypto.meta.cipher_iv_len = EVP_CIPHER_iv_length(ctx->cipher);
    ctx->crypto.meta.hmac_key_len = EVP_MD_size(ctx->digest);
    ctx->crypto.meta.digest_len = tag_len;
    ctx->crypto.meta.tag_len = tag_len;
    ctx->crypto.meta.encryption_capacity = local_encryption_capacity;
    ctx->ns_tag_len = tag_len;
    ctx->payload_len = payload_len;

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
    // cipher and digest (EVP_get_*byname) do not need to be free-ed
    if (ctx->ctx_enc) EVP_CIPHER_CTX_free(ctx->ctx_enc);
    if (ctx->ctx_dec) EVP_CIPHER_CTX_free(ctx->ctx_dec);
    if (ctx->mac) EVP_MAC_free(ctx->mac);
    pp_free(ctx);
    return NULL;
}

void pp_crypto_ctr_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_ctr *ctx = (pp_crypto_ctr *)vctx;

    if (ctx->hmac_key_enc) pp_zd_free(ctx->hmac_key_enc);
    if (ctx->hmac_key_dec) pp_zd_free(ctx->hmac_key_dec);

    EVP_CIPHER_CTX_free(ctx->ctx_enc);
    EVP_CIPHER_CTX_free(ctx->ctx_dec);
    pp_free(ctx->utf_cipher_name);

    pp_free(ctx->utf_digest_name);
    EVP_MAC_free(ctx->mac);
    pp_free(ctx->mac_params);
    pp_zero(ctx->buffer_hmac, ctx->ns_tag_len);
    pp_free(ctx->buffer_hmac);

    pp_free(ctx);
}
