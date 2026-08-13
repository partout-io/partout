/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/crypto.h"
#include "crypto_darwin.h"

bool pp_darwin_crypto_init_seed(const uint8_t *src, const size_t len) {
    (void)src;
    (void)len;
    return true;
}
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
size_t cbc_encryption_capacity(const void *vctx, size_t input_len) {
    const pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    return pp_crypto_encryption_base_capacity(input_len, ctx->crypto.meta.digest_len + ctx->crypto.meta.cipher_iv_len);
}

static
void cbc_configure_encrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
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
size_t cbc_encrypt(void *vctx,
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
void cbc_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
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
bool cbc_verify(void *vctx, const uint8_t *in, size_t in_len, pp_crypto_error_code *error) {
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
size_t cbc_decrypt(void *vctx,
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
    if (!cbc_verify(ctx, in, in_len, error)) {
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

pp_crypto_ctx pp_darwin_crypto_cbc_create(const char *cipher_name,
                                          const char *digest_name,
                                          const pp_crypto_keys *keys) {
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
    ctx->crypto.meta.encryption_capacity = cbc_encryption_capacity;

    ctx->crypto.encrypter.configure = cbc_configure_encrypt;
    ctx->crypto.encrypter.encrypt = cbc_encrypt;
    ctx->crypto.decrypter.configure = cbc_configure_decrypt;
    ctx->crypto.decrypter.decrypt = cbc_decrypt;
    ctx->crypto.decrypter.verify = cbc_verify;

    if (keys) {
        cbc_configure_encrypt(ctx, keys->cipher.enc_key, keys->hmac.enc_key);
        cbc_configure_decrypt(ctx, keys->cipher.dec_key, keys->hmac.dec_key);
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

    pp_zd *_Nullable cipher_key_enc;
    pp_zd *_Nullable cipher_key_dec;
    size_t ns_tag_len;
    size_t payload_len;

    pp_cc_digest digest;
    pp_zd *_Nullable hmac_key_enc;
    pp_zd *_Nullable hmac_key_dec;
    uint8_t *_Nullable buffer_hmac;
} pp_crypto_ctr;

static
size_t ctr_encryption_capacity(const void *vctx, size_t len) {
    const pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    return pp_crypto_encryption_base_capacity(len, ctx->payload_len + ctx->ns_tag_len);
}

static
void ctr_configure_encrypt(void *vctx,
                             const pp_zd *cipher_key, const pp_zd *hmac_key) {
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
bool ctr_crypt(uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const uint8_t *iv,
                     const pp_zd *cipher_key) {
    CCCryptorRef cryptor = NULL;
    CCCryptorStatus status = CCCryptorCreateWithMode(kCCEncrypt,
                                                     kCCModeCTR,
                                                     kCCAlgorithmAES,
                                                     ccNoPadding,
                                                     iv,
                                                     cipher_key->bytes,
                                                     cipher_key->length,
                                                     NULL,
                                                     0,
                                                     0,
                                                     kCCModeOptionCTR_BE,
                                                     &cryptor);
    if (status != kCCSuccess) {
        return false;
    }

    size_t moved = 0;
    status = CCCryptorUpdate(cryptor, in, in_len, out, out_buf_len, &moved);
    if (status == kCCSuccess) {
        size_t final_moved = 0;
        status = CCCryptorFinal(cryptor, out + moved, out_buf_len - moved, &final_moved);
        moved += final_moved;
    }
    CCCryptorRelease(cryptor);
    return status == kCCSuccess && moved == in_len;
}

static
size_t ctr_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->cipher_key_enc);
    pp_assert(ctx->hmac_key_enc);
    pp_assert(flags);
    pp_assert_encryption_length(out_buf_len, in_len);

    uint8_t *out_encrypted = out + ctx->ns_tag_len;

    pp_cc_hmac(&ctx->digest,
               ctx->hmac_key_enc->bytes,
               ctx->hmac_key_enc->length,
               flags->ad,
               flags->ad_len,
               in,
               in_len,
               ctx->buffer_hmac);
    memcpy(out, ctx->buffer_hmac, ctx->ns_tag_len);

    if (!ctr_crypt(out_encrypted,
                         out_buf_len - ctx->ns_tag_len,
                         in,
                         in_len,
                         out,
                         ctx->cipher_key_enc)) {
        if (error) *error = PPCryptoErrorEncryption;
        return 0;
    }

    return ctx->ns_tag_len + in_len;
}

static
void ctr_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
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
size_t ctr_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->cipher_key_dec);
    pp_assert(ctx->hmac_key_dec);
    pp_assert(flags);
    pp_assert_decryption_length(out_buf_len, in_len);

    if (in_len < ctx->ns_tag_len) {
        if (error) *error = PPCryptoErrorEncryption;
        return 0;
    }

    const uint8_t *iv = in;
    const uint8_t *encrypted = in + ctx->ns_tag_len;
    const size_t encrypted_len = in_len - ctx->ns_tag_len;
    if (!ctr_crypt(out,
                         out_buf_len,
                         encrypted,
                         encrypted_len,
                         iv,
                         ctx->cipher_key_dec)) {
        if (error) *error = PPCryptoErrorEncryption;
        return 0;
    }

    pp_cc_hmac(&ctx->digest,
               ctx->hmac_key_dec->bytes,
               ctx->hmac_key_dec->length,
               flags->ad,
               flags->ad_len,
               out,
               encrypted_len,
               ctx->buffer_hmac);

    if (!pp_cc_secure_equal(ctx->buffer_hmac, in, ctx->ns_tag_len)) {
        if (error) *error = PPCryptoErrorHMAC;
        return 0;
    }
    return encrypted_len;
}

// MARK: -

pp_crypto_ctx pp_darwin_crypto_ctr_create(const char *cipher_name,
                                          const char *digest_name,
                                          size_t tag_len, size_t payload_len,
                                          const pp_crypto_keys *keys) {
    pp_assert(cipher_name && digest_name);

    size_t cipher_key_len = 0;
    if (!pp_cc_aes_key_len_by_name(cipher_name, "CTR", &cipher_key_len)) {
        return NULL;
    }

    pp_cc_digest digest;
    if (!pp_cc_digest_by_name(digest_name, &digest)) {
        return NULL;
    }
    if (tag_len > digest.length) {
        return NULL;
    }

    pp_crypto_ctr *ctx = pp_alloc(sizeof(pp_crypto_ctr));
    ctx->digest = digest;
    ctx->buffer_hmac = pp_alloc(digest.length);

    ctx->crypto.meta.cipher_key_len = cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = PP_CC_AES_BLOCK_SIZE;
    ctx->crypto.meta.hmac_key_len = digest.length;
    ctx->crypto.meta.digest_len = tag_len;
    ctx->crypto.meta.tag_len = tag_len;
    ctx->crypto.meta.encryption_capacity = ctr_encryption_capacity;
    ctx->ns_tag_len = tag_len;
    ctx->payload_len = payload_len;

    ctx->crypto.encrypter.configure = ctr_configure_encrypt;
    ctx->crypto.encrypter.encrypt = ctr_encrypt;
    ctx->crypto.decrypter.configure = ctr_configure_decrypt;
    ctx->crypto.decrypter.decrypt = ctr_decrypt;
    ctx->crypto.decrypter.verify = NULL;

    if (keys) {
        ctr_configure_encrypt(ctx, keys->cipher.enc_key, keys->hmac.enc_key);
        ctr_configure_decrypt(ctx, keys->cipher.dec_key, keys->hmac.dec_key);
    }

    return (pp_crypto_ctx)ctx;
}

void pp_darwin_crypto_ctr_free(pp_crypto_ctx vctx) {
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
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/hmac.h"
#include "crypto_darwin.h"

size_t pp_hmac_do(pp_hmac_ctx *ctx) {
    pp_assert(ctx);
    pp_assert(ctx->dst_len >= PP_CC_HMAC_MAX_LENGTH);

    pp_cc_digest digest;
    if (!pp_cc_digest_by_name(ctx->digest_name, &digest)) {
        return 0;
    }

    CCHmac(digest.algorithm,
           ctx->secret, ctx->secret_len,
           ctx->data, ctx->data_len,
           ctx->dst);
    return digest.length;
}
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/function_table.h"
#include "crypto_aead_mbedtls_api.h"
#include "crypto_darwin.h"

pp_crypto_fnt pp_crypto_fnt_native(void) {
    const pp_crypto_enc_fnt enc = {
        pp_darwin_crypto_init_seed,

        pp_mbed_crypto_aead_create,
        pp_mbed_crypto_aead_free,

        pp_darwin_crypto_cbc_create,
        pp_darwin_crypto_cbc_free,

        pp_darwin_crypto_ctr_create,
        pp_darwin_crypto_ctr_free
    };
    pp_crypto_fnt table = pp_crypto_fnt_mbedtls();
    table.name = "native-darwin";
    table.enc = enc;
    return table;
}
