/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <string.h>
#include "portable/common.h"
#include "crypto/crypto_aead.h"
#include "crypto_darwin.h"

typedef struct {
    pp_crypto crypto;

    pp_zd *_Nullable cipher_key_enc;
    pp_zd *_Nullable cipher_key_dec;
    uint8_t *_Nullable iv_enc;
    uint8_t *_Nullable iv_dec;
    size_t id_len;
} pp_crypto_aead;

static inline
void local_prepare_iv(void *vctx, uint8_t *iv, const pp_zd *hmac_key) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->crypto.meta.cipher_iv_len >= ctx->id_len);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.cipher_iv_len - ctx->id_len);
    pp_zero(iv, ctx->id_len);
    memcpy(iv + ctx->id_len, hmac_key->bytes, ctx->crypto.meta.cipher_iv_len - ctx->id_len);
}

static
size_t local_encryption_capacity(const void *vctx, size_t len) {
    const pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    return pp_crypto_encryption_base_capacity(len, ctx->crypto.meta.tag_len);
}

static
void local_configure_encrypt(void *vctx,
                             const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    if (ctx->cipher_key_enc) {
        pp_zd_free(ctx->cipher_key_enc);
    }
    ctx->cipher_key_enc = pp_zd_create_from_data(cipher_key->bytes, ctx->crypto.meta.cipher_key_len);
    local_prepare_iv(ctx, ctx->iv_enc, hmac_key);
}

static
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
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

    const CCCryptorStatus status = CCCryptorGCMOneshotEncrypt(kCCAlgorithmAES,
                                                              ctx->cipher_key_enc->bytes,
                                                              ctx->cipher_key_enc->length,
                                                              ctx->iv_enc,
                                                              cipher_iv_len,
                                                              flags->ad_len ? flags->ad : NULL,
                                                              flags->ad_len,
                                                              in,
                                                              in_len,
                                                              out + tag_len,
                                                              out,
                                                              tag_len);
    if (status != kCCSuccess) {
        if (error) *error = PPCryptoErrorEncryption;
        return 0;
    }
    return tag_len + in_len;
}

static
void local_configure_decrypt(void *vctx,
                             const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    if (ctx->cipher_key_dec) {
        pp_zd_free(ctx->cipher_key_dec);
    }
    ctx->cipher_key_dec = pp_zd_create_from_data(cipher_key->bytes, ctx->crypto.meta.cipher_key_len);
    local_prepare_iv(ctx, ctx->iv_dec, hmac_key);
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
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
        if (error) *error = PPCryptoErrorEncryption;
        return 0;
    }

    if (flags->iv_len > 0) {
        pp_assert(flags->iv);
        memcpy(ctx->iv_dec, flags->iv, (size_t)MIN(flags->iv_len, cipher_iv_len));
    }

    const CCCryptorStatus status = CCCryptorGCMOneshotDecrypt(kCCAlgorithmAES,
                                                              ctx->cipher_key_dec->bytes,
                                                              ctx->cipher_key_dec->length,
                                                              ctx->iv_dec,
                                                              cipher_iv_len,
                                                              flags->ad_len ? flags->ad : NULL,
                                                              flags->ad_len,
                                                              in + tag_len,
                                                              in_len - tag_len,
                                                              out,
                                                              in,
                                                              tag_len);
    if (status != kCCSuccess) {
        if (error) *error = PPCryptoErrorEncryption;
        return 0;
    }
    return in_len - tag_len;
}

// MARK: -

pp_crypto_ctx pp_crypto_aead_create(const char *cipher_name,
                                    size_t tag_len, size_t id_len,
                                    const pp_crypto_keys *keys) {
    pp_assert(cipher_name);

    size_t cipher_key_len = 0;
    if (!pp_cc_aes_key_len_by_name(cipher_name, "GCM", &cipher_key_len)) {
        return NULL;
    }
    if (tag_len > kCCBlockSizeAES128 || id_len > PP_CC_GCM_IV_LENGTH) {
        return NULL;
    }

    pp_crypto_aead *ctx = pp_alloc(sizeof(pp_crypto_aead));

    ctx->crypto.meta.cipher_key_len = cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = PP_CC_GCM_IV_LENGTH;
    ctx->crypto.meta.hmac_key_len = 0;
    ctx->crypto.meta.digest_len = 0;
    ctx->crypto.meta.tag_len = tag_len;
    ctx->crypto.meta.encryption_capacity = local_encryption_capacity;

    ctx->iv_enc = pp_alloc(ctx->crypto.meta.cipher_iv_len);
    ctx->iv_dec = pp_alloc(ctx->crypto.meta.cipher_iv_len);
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

    return (pp_crypto_ctx)ctx;
}

void pp_crypto_aead_free(pp_crypto_ctx vctx) {
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
