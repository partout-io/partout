/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <string.h>
#include "portable/common.h"
#include "crypto/crypto_base.h"
#include "crypto_darwin.h"

typedef struct {
    pp_crypto crypto;

    bool has_cipher;
    pp_zd *_Nullable cipher_key_enc;
    pp_zd *_Nullable cipher_key_dec;

    pp_cc_digest digest;
    uint8_t buffer_hmac[PP_CC_HMAC_MAX_LENGTH];
    pp_zd *_Nullable hmac_key_enc;
    pp_zd *_Nullable hmac_key_dec;
} pp_crypto_cbc;

static
size_t local_encryption_capacity(const void *vctx, size_t input_len) {
    const pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    return pp_crypto_encryption_base_capacity(input_len, ctx->crypto.meta.digest_len + ctx->crypto.meta.cipher_iv_len);
}

static
void local_configure_encrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
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
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
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
            if (CCRandomGenerateBytes(out_iv, cipher_iv_len) != kCCSuccess) {
                if (error) *error = PPCryptoErrorEncryption;
                return 0;
            }
        }
        const CCCryptorStatus status = CCCrypt(kCCEncrypt,
                                               kCCAlgorithmAES,
                                               kCCOptionPKCS7Padding,
                                               ctx->cipher_key_enc->bytes,
                                               ctx->cipher_key_enc->length,
                                               out_iv,
                                               in,
                                               in_len,
                                               out_encrypted,
                                               out_buf_len - (size_t)(out_encrypted - out),
                                               &encrypted_len);
        if (status != kCCSuccess) {
            if (error) *error = PPCryptoErrorEncryption;
            return 0;
        }
    } else {
        pp_assert(out_encrypted == out_iv);
        memcpy(out_encrypted, in, in_len);
        encrypted_len = in_len;
    }

    pp_cc_hmac(&ctx->digest,
               ctx->hmac_key_enc->bytes,
               ctx->hmac_key_enc->length,
               out_iv,
               encrypted_len + cipher_iv_len,
               NULL,
               0,
               out);

    return encrypted_len + cipher_iv_len + digest_len;
}

static
void local_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
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
bool local_verify(void *vctx, const uint8_t *in, size_t in_len, pp_crypto_error_code *error) {
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->hmac_key_dec);

    const size_t digest_len = ctx->crypto.meta.digest_len;
    if (in_len < digest_len) {
        if (error) *error = PPCryptoErrorHMAC;
        return false;
    }

    pp_cc_hmac(&ctx->digest,
               ctx->hmac_key_dec->bytes,
               ctx->hmac_key_dec->length,
               in + digest_len,
               in_len - digest_len,
               NULL,
               0,
               ctx->buffer_hmac);

    if (!pp_cc_secure_equal(ctx->buffer_hmac, in, digest_len)) {
        if (error) *error = PPCryptoErrorHMAC;
        return false;
    }
    return true;
}

static
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    (void)flags;
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    pp_assert(!ctx->has_cipher || ctx->cipher_key_dec);
    pp_assert(ctx->hmac_key_dec);
    pp_assert_decryption_length(out_buf_len, in_len);

    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    if (in_len < digest_len + cipher_iv_len) {
        if (error) *error = PPCryptoErrorEncryption;
        return 0;
    }
    if (!local_verify(ctx, in, in_len, error)) {
        return 0;
    }

    const uint8_t *iv = in + digest_len;
    const uint8_t *encrypted = in + digest_len + cipher_iv_len;
    const size_t encrypted_len = in_len - digest_len - cipher_iv_len;
    size_t out_len = 0;

    if (ctx->has_cipher) {
        const CCCryptorStatus status = CCCrypt(kCCDecrypt,
                                               kCCAlgorithmAES,
                                               kCCOptionPKCS7Padding,
                                               ctx->cipher_key_dec->bytes,
                                               ctx->cipher_key_dec->length,
                                               iv,
                                               encrypted,
                                               encrypted_len,
                                               out,
                                               out_buf_len,
                                               &out_len);
        if (status != kCCSuccess) {
            if (error) *error = PPCryptoErrorEncryption;
            return 0;
        }
    } else {
        memcpy(out, in + digest_len, in_len - digest_len);
        out_len = in_len - digest_len;
    }
    return out_len;
}

// MARK: -

pp_crypto_ctx pp_darwin_crypto_cbc_create(const char *_Nullable cipher_name,
                                          const char *digest_name,
                                          const pp_crypto_keys *_Nullable keys) {
    pp_assert(digest_name);

    size_t cipher_key_len = 0;
    size_t cipher_iv_len = 0;
    if (cipher_name) {
        if (!pp_cc_aes_key_len_by_name(cipher_name, "CBC", &cipher_key_len)) {
            return NULL;
        }
        cipher_iv_len = PP_CC_AES_BLOCK_SIZE;
    }

    pp_cc_digest digest;
    if (!pp_cc_digest_by_name(digest_name, &digest)) {
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

    return (pp_crypto_ctx)ctx;
}

void pp_darwin_crypto_cbc_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_cbc *ctx = (pp_crypto_cbc *)vctx;

    if (ctx->cipher_key_enc) pp_zd_free(ctx->cipher_key_enc);
    if (ctx->cipher_key_dec) pp_zd_free(ctx->cipher_key_dec);
    if (ctx->hmac_key_enc) pp_zd_free(ctx->hmac_key_enc);
    if (ctx->hmac_key_dec) pp_zd_free(ctx->hmac_key_dec);
    pp_zero(ctx->buffer_hmac, PP_CC_HMAC_MAX_LENGTH);

    pp_free(ctx);
}
