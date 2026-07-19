/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/rand.h>
#include "crypto/crypto.h"
#include "crypto_openssl.h"

bool pp_openssl_crypto_init_seed(const uint8_t *src, const size_t len) {
    unsigned char x[1];
    if (RAND_bytes(x, 1) != 1) {
        return false;
    }
    RAND_seed(src, (int)len);
    return true;
}
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/evp.h>
#include <string.h>
#include "portable/common.h"
#include "crypto/crypto_base.h"
#include "crypto_openssl.h"

typedef struct {
    pp_crypto crypto;

    // Cipher
    const EVP_CIPHER *_Nonnull cipher;
    EVP_CIPHER_CTX *_Nonnull ctx_enc;
    EVP_CIPHER_CTX *_Nonnull ctx_dec;
    uint8_t *_Nonnull iv_enc;
    uint8_t *_Nonnull iv_dec;
    size_t id_len;
} pp_crypto_aead;

static inline
void aead_prepare_iv(void *vctx, uint8_t *_Nonnull iv, const pp_zd *_Nonnull hmac_key) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_zero(iv, ctx->id_len);
    memcpy(iv + ctx->id_len, hmac_key->bytes, ctx->crypto.meta.cipher_iv_len - ctx->id_len);
}

size_t aead_encryption_capacity(const void *vctx, size_t len) {
    const pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    return pp_crypto_encryption_base_capacity(len, ctx->crypto.meta.tag_len);
}

static
void aead_configure_encrypt(void *vctx,
                             const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    PP_CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_enc))
    PP_CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_enc, ctx->cipher, cipher_key->bytes, NULL, 1))
    aead_prepare_iv(ctx, ctx->iv_enc, hmac_key);
}

static
size_t aead_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags,
                     pp_crypto_error_code *error) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->ctx_enc);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);
    pp_assert_encryption_length(out_buf_len, in_len);

    EVP_CIPHER_CTX *ossl = ctx->ctx_enc;
    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t tag_len = ctx->crypto.meta.tag_len;
    int aad_len = 0;
    int ciphertext_len = 0;
    int final_len = 0;

    memcpy(ctx->iv_enc, flags->iv, (size_t)MIN(flags->iv_len, cipher_iv_len));

    PP_CRYPTO_CHECK(EVP_CipherInit(ossl, NULL, NULL, ctx->iv_enc, -1))
    PP_CRYPTO_CHECK(EVP_CipherUpdate(ossl, NULL, &aad_len, flags->ad, (int)flags->ad_len))
    PP_CRYPTO_CHECK(EVP_CipherUpdate(ossl, out + tag_len, &ciphertext_len, in, (int)in_len))
    PP_CRYPTO_CHECK(EVP_CipherFinal_ex(ossl, out + tag_len + ciphertext_len, &final_len))
    PP_CRYPTO_CHECK(EVP_CIPHER_CTX_ctrl(ossl, EVP_CTRL_GCM_GET_TAG, (int)tag_len, out))

    const size_t out_len = tag_len + ciphertext_len + final_len;
    return out_len;
}

static
void aead_configure_decrypt(void *vctx,
                             const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    PP_CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_dec))
    PP_CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_dec, ctx->cipher, cipher_key->bytes, NULL, 0))
    aead_prepare_iv(ctx, ctx->iv_dec, hmac_key);
}

static
size_t aead_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags,
                     pp_crypto_error_code *error) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->ctx_dec);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);
    pp_assert_decryption_length(out_buf_len, in_len);

    EVP_CIPHER_CTX *ossl = ctx->ctx_dec;
    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t tag_len = ctx->crypto.meta.tag_len;
    int aad_len = 0;
    int plaintext_len = 0;
    int final_len = 0;

    memcpy(ctx->iv_dec, flags->iv, (size_t)MIN(flags->iv_len, cipher_iv_len));

    PP_CRYPTO_CHECK(EVP_CipherInit(ossl, NULL, NULL, ctx->iv_dec, -1))
    PP_CRYPTO_CHECK(EVP_CIPHER_CTX_ctrl(ossl, EVP_CTRL_GCM_SET_TAG, (int)tag_len, (void *)in))
    PP_CRYPTO_CHECK(EVP_CipherUpdate(ossl, NULL, &aad_len, flags->ad, (int)flags->ad_len))
    PP_CRYPTO_CHECK(EVP_CipherUpdate(ossl, out, &plaintext_len, in + tag_len, (int)(in_len - tag_len)))
    PP_CRYPTO_CHECK(EVP_CipherFinal_ex(ossl, out + plaintext_len, &final_len))

    const size_t out_len = plaintext_len + final_len;
    return out_len;
}

// MARK: -

pp_crypto_ctx pp_openssl_crypto_aead_create(const char *cipher_name,
                                            size_t tag_len, size_t id_len,
                                            const pp_crypto_keys *keys) {
    pp_assert(cipher_name);

    pp_crypto_aead *ctx = pp_alloc(sizeof(pp_crypto_aead));
    ctx->cipher = EVP_get_cipherbyname(cipher_name);
    if (!ctx->cipher) {
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

    // no longer fails

    ctx->crypto.meta.cipher_key_len = EVP_CIPHER_key_length(ctx->cipher);
    ctx->crypto.meta.cipher_iv_len = EVP_CIPHER_iv_length(ctx->cipher);
    ctx->crypto.meta.hmac_key_len = 0;
    ctx->crypto.meta.digest_len = 0;
    ctx->crypto.meta.tag_len = tag_len;
    ctx->crypto.meta.encryption_capacity = aead_encryption_capacity;

    ctx->iv_enc = pp_alloc(ctx->crypto.meta.cipher_iv_len);
    ctx->iv_dec = pp_alloc(ctx->crypto.meta.cipher_iv_len);
    ctx->id_len = id_len;

    ctx->crypto.encrypter.configure = aead_configure_encrypt;
    ctx->crypto.encrypter.encrypt = aead_encrypt;
    ctx->crypto.decrypter.configure = aead_configure_decrypt;
    ctx->crypto.decrypter.decrypt = aead_decrypt;
    ctx->crypto.decrypter.verify = NULL;

    if (keys) {
        aead_configure_encrypt(ctx, keys->cipher.enc_key, keys->hmac.enc_key);
        aead_configure_decrypt(ctx, keys->cipher.dec_key, keys->hmac.dec_key);
    }

    return (pp_crypto_ctx)ctx;

failure:
    if (ctx->ctx_enc) EVP_CIPHER_CTX_free(ctx->ctx_enc);
    if (ctx->ctx_dec) EVP_CIPHER_CTX_free(ctx->ctx_dec);
    pp_free(ctx);
    return NULL;
}

void pp_openssl_crypto_aead_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_aead *ctx = (pp_crypto_aead *)vctx;

    EVP_CIPHER_CTX_free(ctx->ctx_enc);
    EVP_CIPHER_CTX_free(ctx->ctx_dec);
    pp_zero(ctx->iv_enc, ctx->crypto.meta.cipher_iv_len);
    pp_zero(ctx->iv_dec, ctx->crypto.meta.cipher_iv_len);
    pp_free(ctx->iv_enc);
    pp_free(ctx->iv_dec);
    pp_free(ctx);
}
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/evp.h>
#include <openssl/rand.h>
#include <string.h>
#include "portable/common.h"
#include "crypto/crypto_base.h"
#include "crypto_openssl.h"

#define HMACMaxLength (size_t)128

typedef struct {
    pp_crypto crypto;

    // Cipher
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
    pp_zd *_Nonnull hmac_key_enc;
    pp_zd *_Nonnull hmac_key_dec;
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

    if (ctx->cipher) {
        pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
        PP_CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_enc))
        PP_CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_enc, ctx->cipher, cipher_key->bytes, NULL, 1))
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
    pp_assert(!ctx->cipher || ctx->ctx_enc);
    pp_assert(ctx->hmac_key_enc);
    pp_assert_encryption_length(out_buf_len, in_len);

    // output = [-digest-|-iv-|-payload-]
    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    uint8_t *out_iv = out + digest_len;
    uint8_t *out_encrypted = out_iv + cipher_iv_len;
    int ciphertext_len = 0;
    int final_len = 0;
    size_t mac_len = 0;

    if (ctx->cipher) {
        if (!flags || !flags->for_testing) {
            if (RAND_bytes(out_iv, (int)cipher_iv_len) != 1) {
                return false;
            }
        }
        PP_CRYPTO_CHECK(EVP_CipherInit(ctx->ctx_enc, NULL, NULL, out_iv, -1))
        PP_CRYPTO_CHECK(EVP_CipherUpdate(ctx->ctx_enc, out_encrypted, &ciphertext_len, in, (int)in_len))
        PP_CRYPTO_CHECK(EVP_CipherFinal_ex(ctx->ctx_enc, out_encrypted + ciphertext_len, &final_len))
    } else {
        pp_assert(out_encrypted == out_iv);
        memcpy(out_encrypted, in, in_len);
        ciphertext_len = (int)in_len;
    }

    EVP_MAC_CTX *mac_ctx = EVP_MAC_CTX_new(ctx->mac);
    PP_CRYPTO_CHECK_MAC(EVP_MAC_init(mac_ctx, ctx->hmac_key_enc->bytes, ctx->hmac_key_enc->length, ctx->mac_params))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, out_iv, ciphertext_len + final_len + cipher_iv_len))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_final(mac_ctx, out, &mac_len, digest_len))
    EVP_MAC_CTX_free(mac_ctx);

    const size_t out_len = ciphertext_len + final_len + cipher_iv_len + digest_len;
    return out_len;
}

static
void cbc_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->cipher) {
        pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
        PP_CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_dec))
        PP_CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_dec, ctx->cipher, cipher_key->bytes, NULL, 0))
    }
    if (ctx->hmac_key_dec) {
        pp_zd_free(ctx->hmac_key_dec);
    }
    ctx->hmac_key_dec = pp_zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t cbc_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    (void)flags;
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    pp_assert(!ctx->cipher || ctx->ctx_dec);
    pp_assert(ctx->hmac_key_dec);
    pp_assert_decryption_length(out_buf_len, in_len);

    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const uint8_t *iv = in + digest_len;
    const uint8_t *encrypted = in + digest_len + cipher_iv_len;
    size_t mac_len = 0;

    EVP_MAC_CTX *mac_ctx = EVP_MAC_CTX_new(ctx->mac);
    PP_CRYPTO_CHECK_MAC(EVP_MAC_init(mac_ctx, ctx->hmac_key_dec->bytes, ctx->hmac_key_dec->length, ctx->mac_params))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, in + digest_len, in_len - digest_len))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_final(mac_ctx, ctx->buffer_hmac, &mac_len, digest_len))
    EVP_MAC_CTX_free(mac_ctx);

    pp_assert(mac_len == digest_len);
    if (CRYPTO_memcmp(ctx->buffer_hmac, in, mac_len) != 0) {
        PP_CRYPTO_SET_ERROR(PPCryptoErrorHMAC)
        return 0;
    }

    size_t out_len = 0;
    if (ctx->cipher) {
        size_t plaintext_len = 0;
        size_t final_len = 0;
        PP_CRYPTO_CHECK(EVP_CipherInit(ctx->ctx_dec, NULL, NULL, iv, -1))
        PP_CRYPTO_CHECK(EVP_CipherUpdate(ctx->ctx_dec, out, (int *)&plaintext_len, encrypted, (int)(in_len - mac_len - cipher_iv_len)))
        PP_CRYPTO_CHECK(EVP_CipherFinal_ex(ctx->ctx_dec, out + plaintext_len, (int *)&final_len))
        out_len = plaintext_len + final_len;
    } else {
        out_len = in_len - mac_len;
        memcpy(out, in + mac_len, out_len);
    }
    return out_len;
}

static
bool cbc_verify(void *vctx, const uint8_t *in, size_t in_len, pp_crypto_error_code *error) {
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);

    const size_t digest_len = ctx->crypto.meta.digest_len;
    size_t mac_len = 0;
    EVP_MAC_CTX *mac_ctx = EVP_MAC_CTX_new(ctx->mac);
    PP_CRYPTO_CHECK_MAC(EVP_MAC_init(mac_ctx, ctx->hmac_key_dec->bytes, ctx->hmac_key_dec->length, ctx->mac_params))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_update(mac_ctx, in + digest_len, in_len - digest_len))
    PP_CRYPTO_CHECK_MAC(EVP_MAC_final(mac_ctx, ctx->buffer_hmac, &mac_len, digest_len))
    EVP_MAC_CTX_free(mac_ctx);

    pp_assert(mac_len == digest_len);
    if (CRYPTO_memcmp(ctx->buffer_hmac, in, mac_len) != 0) {
        PP_CRYPTO_SET_ERROR(PPCryptoErrorHMAC)
        return false;
    }
    return true;
}

// MARK: -

pp_crypto_ctx pp_openssl_crypto_cbc_create(const char *cipher_name,
                                           const char *digest_name,
                                           const pp_crypto_keys *keys) {
    pp_assert(digest_name);

    pp_crypto_cbc *ctx = pp_alloc(sizeof(pp_crypto_cbc));
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

    ctx->mac_params = pp_alloc(2 * sizeof(OSSL_PARAM));
    ctx->mac_params[0] = OSSL_PARAM_construct_utf8_string("digest", ctx->utf_digest_name, 0);
    ctx->mac_params[1] = OSSL_PARAM_construct_end();

    if (ctx->cipher) {
        ctx->crypto.meta.cipher_key_len = EVP_CIPHER_key_length(ctx->cipher);
        ctx->crypto.meta.cipher_iv_len = EVP_CIPHER_iv_length(ctx->cipher);
    }
    ctx->crypto.meta.hmac_key_len = EVP_MD_size(ctx->digest);
    ctx->crypto.meta.digest_len = ctx->crypto.meta.hmac_key_len;
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

failure:
    // cipher and digest (EVP_get_*byname) do not need to be free-ed
    if (ctx->ctx_enc) EVP_CIPHER_CTX_free(ctx->ctx_enc);
    if (ctx->ctx_dec) EVP_CIPHER_CTX_free(ctx->ctx_dec);
    if (ctx->mac) EVP_MAC_free(ctx->mac);
    pp_free(ctx);
    return NULL;
}

void pp_openssl_crypto_cbc_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_cbc *ctx = (pp_crypto_cbc *)vctx;

    if (ctx->hmac_key_enc) pp_zd_free(ctx->hmac_key_enc);
    if (ctx->hmac_key_dec) pp_zd_free(ctx->hmac_key_dec);

    if (ctx->cipher) {
        EVP_CIPHER_CTX_free(ctx->ctx_enc);
        EVP_CIPHER_CTX_free(ctx->ctx_dec);
        pp_free(ctx->utf_cipher_name);
    }

    pp_free(ctx->utf_digest_name);
    EVP_MAC_free(ctx->mac);
    pp_free(ctx->mac_params);
    pp_zero(ctx->buffer_hmac, HMACMaxLength);

    pp_free(ctx);
}
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/evp.h>
#include <string.h>
#include "portable/common.h"
#include "crypto/crypto_base.h"
#include "crypto_openssl.h"

typedef struct {
    pp_crypto crypto;

    // Cipher
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

    PP_CRYPTO_ASSERT(EVP_CIPHER_CTX_reset(ctx->ctx_enc))
    PP_CRYPTO_ASSERT(EVP_CipherInit(ctx->ctx_enc, ctx->cipher, cipher_key->bytes, NULL, 1))
    if (ctx->hmac_key_enc) {
        pp_zd_free(ctx->hmac_key_enc);
    }
    ctx->hmac_key_enc = pp_zd_create_from_data(hmac_key->bytes, ctx->crypto.meta.hmac_key_len);
}

static
size_t ctr_encrypt(void *vctx,
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
void ctr_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
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
size_t ctr_decrypt(void *vctx,
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

pp_crypto_ctx pp_openssl_crypto_ctr_create(const char *cipher_name,
                                           const char *digest_name,
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

failure:
    // cipher and digest (EVP_get_*byname) do not need to be free-ed
    if (ctx->ctx_enc) EVP_CIPHER_CTX_free(ctx->ctx_enc);
    if (ctx->ctx_dec) EVP_CIPHER_CTX_free(ctx->ctx_dec);
    if (ctx->mac) EVP_MAC_free(ctx->mac);
    pp_free(ctx);
    return NULL;
}

void pp_openssl_crypto_ctr_free(pp_crypto_ctx vctx) {
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
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/hmac.h>
#include "crypto/hmac.h"
#include "portable/common.h"
#include "crypto_openssl.h"

#define HMACMaxLength    (size_t)128

size_t pp_openssl_hmac_do(pp_hmac_ctx *ctx) {
    pp_assert(ctx->dst_len >= HMACMaxLength);

    const EVP_MD *md = EVP_get_digestbyname(ctx->digest_name);
    if (!md) {
        return 0;
    }
    unsigned int dst_len = 0;
    const bool success = HMAC(md, ctx->secret, (int)ctx->secret_len,
                              ctx->data, ctx->data_len,
                              ctx->dst, &dst_len) != NULL;
    if (!success) {
        return 0;
    }
    return dst_len;
}
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include "portable/common.h"
#include "crypto/hmac.h"
#include "crypto/keys.h"
#include "crypto_openssl.h"

static
char *pp_key_decrypted_from_pkey(const EVP_PKEY *_Nonnull key) {
    BIO *output = BIO_new(BIO_s_mem());
    if (!PEM_write_bio_PrivateKey(output, key, NULL, NULL, 0, NULL, NULL)) {
        BIO_free(output);
        return NULL;
    }

    size_t dec_len = BIO_ctrl_pending(output);
    char *dec_bytes = pp_alloc(dec_len + 1);
    if (BIO_read(output, dec_bytes, (int)dec_len) < 0) {
        BIO_free(output);
        return NULL;
    }
    BIO_free(output);

    dec_bytes[dec_len] = '\0';
    return dec_bytes;
}

static
char *pp_key_decrypted_from_bio(BIO *_Nonnull bio, const char *_Nonnull passphrase) {
    EVP_PKEY *key;
    if (!(key = PEM_read_bio_PrivateKey(bio, NULL, NULL, (void *)passphrase))) {
        return NULL;
    }
    char *ret = pp_key_decrypted_from_pkey(key);
    EVP_PKEY_free(key);
    return ret;
}

char *pp_openssl_key_decrypted_from_path(const char *path, const char *passphrase) {
    BIO *bio;
    if (!(bio = BIO_new_file(path, "r"))) {
        return NULL;
    }
    char *ret = pp_key_decrypted_from_bio(bio, passphrase);
    BIO_free(bio);
    return ret;
}

char *pp_openssl_key_decrypted_from_pem(const char *pem, const char *passphrase) {
    BIO *bio;
    if (!(bio = BIO_new_mem_buf(pem, (int)strlen(pem)))) {
        return NULL;
    }
    char *ret = pp_key_decrypted_from_bio(bio, passphrase);
    BIO_free(bio);
    return ret;
}
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <openssl/err.h>
#include <stdio.h>
#include "portable/common.h"
#include "crypto/tls.h"
#include "crypto_openssl.h"

//static const char *const TLSBoxClientEKU = "TLS Web Client Authentication";
static const char *const TLSBoxServerEKU = "TLS Web Server Authentication";

static int PPTLSExDataIdx = -1;

struct __pp_tls_struct {
    const pp_tls_options *_Nonnull opt;
    SSL_CTX *_Nonnull ssl_ctx;
    size_t buf_len;
    uint8_t *_Nonnull buf_cipher;
    uint8_t *_Nonnull buf_plain;

    SSL *_Nonnull ssl;
    BIO *_Nonnull bio_plain;
    BIO *_Nonnull bio_cipher_in;
    BIO *_Nonnull bio_cipher_out;
    bool is_connected;
};

static
BIO *create_BIO_from_PEM(const char *_Nonnull pem) {
    return BIO_new_mem_buf(pem, (int)strlen(pem));
}

static
int pp_tls_verify_peer(int ok, X509_STORE_CTX *_Nonnull ctx) {
    if (ok == 0) {
        pp_clog_v(PPLogCategoryCore, PPLogLevelError,
                  "pp_tls_verify_peer: error %d", X509_STORE_CTX_get_error(ctx));
        SSL *ssl = X509_STORE_CTX_get_ex_data(ctx, SSL_get_ex_data_X509_STORE_CTX_idx());
        if (!ssl) {
            pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tls_verify_peer: NULL ssl");
            abort();
        }
        pp_tls tls = SSL_get_ex_data(ssl, PPTLSExDataIdx);
        if (!tls) {
            pp_clog(PPLogCategoryCore, PPLogLevelFault, "pp_tls_verify_peer: NULL tls");
            abort();
        }
        tls->opt->on_verify_failure(tls->opt->ctx);
    }
    return ok;
}

// MARK: -

pp_tls pp_openssl_tls_create(const pp_tls_options *opt, pp_tls_error_code *error) {
    SSL_CTX *ssl_ctx = SSL_CTX_new(TLS_client_method());
    X509 *cert = NULL;
    BIO *cert_bio = NULL;
    EVP_PKEY *pkey = NULL;
    BIO *pkey_bio = NULL;

    SSL_CTX_set_options(ssl_ctx, SSL_OP_NO_SSLv2 | SSL_OP_NO_SSLv3 | SSL_OP_NO_COMPRESSION);
    SSL_CTX_set_verify(ssl_ctx, SSL_VERIFY_PEER, pp_tls_verify_peer);
    SSL_CTX_set_security_level(ssl_ctx, opt->sec_level);

    if (opt->ca_path) {
        if (!SSL_CTX_load_verify_locations(ssl_ctx, opt->ca_path, NULL)) {
            PP_CRYPTO_SET_ERROR(PPTLSErrorCAUse)
            goto failure;
        }
    }
    if (opt->cert_pem) {
        cert_bio = create_BIO_from_PEM(opt->cert_pem);
        if (!cert_bio) {
            PP_CRYPTO_SET_ERROR(PPTLSErrorClientCertificateRead)
            goto failure;
        }
        cert = PEM_read_bio_X509(cert_bio, NULL, NULL, NULL);
        if (!cert) {
            PP_CRYPTO_SET_ERROR(PPTLSErrorClientCertificateRead)
            goto failure;
        }
        if (!SSL_CTX_use_certificate(ssl_ctx, cert)) {
            PP_CRYPTO_SET_ERROR(PPTLSErrorClientCertificateUse)
            goto failure;
        }
        X509_free(cert);
        BIO_free(cert_bio);
        cert = NULL;
        cert_bio = NULL;

        if (opt->key_pem) {
            pkey_bio = create_BIO_from_PEM(opt->key_pem);
            if (!pkey_bio) {
                PP_CRYPTO_SET_ERROR(PPTLSErrorClientKeyRead)
                goto failure;
            }
            pkey = PEM_read_bio_PrivateKey(pkey_bio, NULL, NULL, NULL);
            if (!pkey) {
                PP_CRYPTO_SET_ERROR(PPTLSErrorClientKeyRead)
                goto failure;
            }
            if (!SSL_CTX_use_PrivateKey(ssl_ctx, pkey)) {
                PP_CRYPTO_SET_ERROR(PPTLSErrorClientKeyUse)
                goto failure;
            }
            EVP_PKEY_free(pkey);
            BIO_free(pkey_bio);
        }
    }

    // no longer fails

    pp_tls tls = pp_alloc(sizeof(*tls));
    tls->opt = opt;
    tls->ssl_ctx = ssl_ctx;
    tls->buf_len = tls->opt->buf_len;
    tls->buf_cipher = pp_alloc(tls->buf_len);
    tls->buf_plain = pp_alloc(tls->buf_len);
    return tls;

failure:
    ERR_print_errors_fp(stdout);
    SSL_CTX_free(ssl_ctx);
    if (cert) X509_free(cert);
    if (cert_bio) BIO_free(cert_bio);
    if (pkey) EVP_PKEY_free(pkey);
    if (pkey_bio) BIO_free(pkey_bio);
    return NULL;
}

void pp_openssl_tls_free(pp_tls tls) {
    if (!tls) return;

    // DO NOT FREE these due to use in BIO_set_ssl() macro
//    if (self.bioCipherTextIn) {
//        BIO_free(self.bioCipherTextIn);
//    }
//    if (self.bioCipherTextOut) {
//        BIO_free(self.bioCipherTextOut);
//    }
    if (tls->bio_plain) {
        BIO_free_all(tls->bio_plain);
    }
    if (tls->ssl) {
        SSL_free(tls->ssl);
    }

    pp_zero(tls->buf_cipher, tls->opt->buf_len);
    pp_zero(tls->buf_plain, tls->opt->buf_len);
    pp_free(tls->buf_cipher);
    pp_free(tls->buf_plain);
    pp_tls_options_free((pp_tls_options *)tls->opt);
    SSL_CTX_free(tls->ssl_ctx);
}

bool pp_openssl_tls_start(pp_tls tls) {
    if (tls->bio_plain) {
        BIO_free_all(tls->bio_plain);
        tls->bio_plain = NULL;
        tls->bio_cipher_in = NULL;
        tls->bio_cipher_out = NULL;
    }
    if (tls->ssl) {
        SSL_free(tls->ssl);
        tls->ssl = NULL;
    }
    pp_zero(tls->buf_cipher, tls->opt->buf_len);
    pp_zero(tls->buf_plain, tls->opt->buf_len);
    tls->is_connected = false;

    tls->ssl = SSL_new(tls->ssl_ctx);
    tls->bio_plain = BIO_new(BIO_f_ssl());
    tls->bio_cipher_in = BIO_new(BIO_s_mem());
    tls->bio_cipher_out = BIO_new(BIO_s_mem());

    SSL_set_connect_state(tls->ssl);
    SSL_set_bio(tls->ssl, tls->bio_cipher_in, tls->bio_cipher_out);
    BIO_set_ssl(tls->bio_plain, tls->ssl, BIO_NOCLOSE);

    // attach custom object
    if (PPTLSExDataIdx == -1) {
        PPTLSExDataIdx = SSL_get_ex_new_index(0, NULL, NULL, NULL, NULL);
    }
    SSL_set_ex_data(tls->ssl, PPTLSExDataIdx, tls);

    return SSL_do_handshake(tls->ssl);
}

bool pp_openssl_tls_is_connected(pp_tls tls) {
    return tls->is_connected;
}

// MARK: - I/O

bool pp_tls_verify_ssl_eku(SSL *ssl);
bool pp_tls_verify_ssl_san_host(SSL *ssl, const char *hostname);

pp_zd *pp_openssl_tls_pull_cipher(pp_tls tls, pp_tls_error_code *error) {
    if (error) {
        *error = PPTLSErrorNone;
    }
    if (!tls->is_connected && !SSL_is_init_finished(tls->ssl)) {
        SSL_do_handshake(tls->ssl);
    }
    const int ret = BIO_read(tls->bio_cipher_out, tls->buf_cipher, (int)tls->opt->buf_len);
    if (!tls->is_connected && SSL_is_init_finished(tls->ssl)) {
        tls->is_connected = true;
        if (tls->opt->eku && !pp_tls_verify_ssl_eku(tls->ssl)) {
            if (error) {
                *error = PPTLSErrorServerEKU;
            }
            return NULL;
        }
        if (tls->opt->san_host) {
            pp_assert(tls->opt->hostname);
            if (!pp_tls_verify_ssl_san_host(tls->ssl, tls->opt->hostname)) {
                if (error) {
                    *error = PPTLSErrorServerHost;
                }
                return NULL;
            }
        }
    }
    if ((ret < 0) && !BIO_should_retry(tls->bio_cipher_out)) {
        if (error) {
            *error = PPTLSErrorHandshake;
        }
        return NULL;
    }
    if (ret <= 0) {
        return NULL;
    }
    return pp_zd_create_from_data(tls->buf_cipher, ret);
}

pp_zd *pp_openssl_tls_pull_plain(pp_tls tls, pp_tls_error_code *error) {
    const int ret = BIO_read(tls->bio_plain, tls->buf_plain, (int)tls->opt->buf_len);
    if (error) {
        *error = PPTLSErrorNone;
    }
    if ((ret < 0) && !BIO_should_retry(tls->bio_plain)) {
        if (error) {
            *error = PPTLSErrorHandshake;
        }
        return NULL;
    }
    if (ret <= 0) {
        return NULL;
    }
    return pp_zd_create_from_data(tls->buf_plain, ret);
}

bool pp_openssl_tls_put_cipher(pp_tls tls,
                               const uint8_t *src, size_t src_len,
                               pp_tls_error_code *error) {
    if (error) {
        *error = PPTLSErrorNone;
    }
    const int ret = BIO_write(tls->bio_cipher_in, src, (int)src_len);
    if (ret != (int)src_len) {
        if (error) {
            *error = PPTLSErrorHandshake;
        }
        return false;
    }
    return true;
}

bool pp_openssl_tls_put_plain(pp_tls tls,
                              const uint8_t *src, size_t src_len,
                              pp_tls_error_code *error) {
    if (error) {
        *error = PPTLSErrorNone;
    }
    const int ret = BIO_write(tls->bio_plain, src, (int)src_len);
    if (ret != (int)src_len) {
        if (error) {
            *error = PPTLSErrorHandshake;
        }
        return false;
    }
    return true;
}

// MARK: - MD5

char *pp_openssl_tls_ca_md5(const pp_tls tls) {
    const EVP_MD *alg = EVP_get_digestbyname("MD5");
    uint8_t md[16];
    unsigned int len;

    FILE *pem = pp_fopen(tls->opt->ca_path, "r");
    if (!pem) {
        goto failure;
    }
    X509 *cert = PEM_read_X509(pem, NULL, NULL, NULL);
    if (!cert) {
        goto failure;
    }
    X509_digest(cert, alg, md, &len);
    X509_free(cert);
    fclose(pem);
    pp_assert(len == sizeof(md));//, @"Unexpected MD5 size (%d != %lu)", len, sizeof(md));

    char *hex = pp_alloc(2 * sizeof(md) + 1);
    char *ptr = hex;
    for (size_t i = 0; i < sizeof(md); ++i) {
        ptr += snprintf(ptr, 3, "%02x", md[i]);
    }
    *ptr = '\0';
    return hex;

failure:
    if (pem) fclose(pem);
    return NULL;
}

// MARK: - Verifications

bool pp_tls_verify_ssl_eku(SSL *ssl) {
    X509 *cert = NULL;
    EXTENDED_KEY_USAGE *eku = NULL;

    cert = SSL_get1_peer_certificate(ssl);
    if (!cert) {
        goto failure;
    }

    // don't be afraid of saving some time:
    //
    // https://stackoverflow.com/questions/37047379/how-extract-all-oids-from-certificate-with-openssl
    //
    const int ext_index = X509_get_ext_by_NID(cert, NID_ext_key_usage, -1);
    if (ext_index < 0) {
        goto failure;
    }
    X509_EXTENSION *ext = X509_get_ext(cert, ext_index);
    if (!ext) {
        goto failure;
    }
    eku = X509V3_EXT_d2i(ext);
    if (!eku) {
        goto failure;
    }

    const int num = (int)sk_ASN1_OBJECT_num(eku);
    char buffer[100];
    bool is_valid = false;
    for (int i = 0; i < num; ++i) {
        OBJ_obj2txt(buffer, sizeof(buffer), sk_ASN1_OBJECT_value(eku, i), 1); // get OID
        const char *oid = OBJ_nid2ln(OBJ_obj2nid(sk_ASN1_OBJECT_value(eku, i)));
        if (oid && !strcmp(oid, TLSBoxServerEKU)) {
            is_valid = true;
            break;
        }
    }
    EXTENDED_KEY_USAGE_free(eku);
    X509_free(cert);
    return is_valid;

failure:
    if (eku) EXTENDED_KEY_USAGE_free(eku);
    if (cert) X509_free(cert);
    return false;
}

bool pp_tls_verify_ssl_san_host(SSL *ssl, const char *hostname) {
    X509 *cert = NULL;
    GENERAL_NAMES *names = NULL;

    cert = SSL_get1_peer_certificate(ssl);
    if (!cert) {
        goto failure;
    }
    names = X509_get_ext_d2i(cert, NID_subject_alt_name, 0, 0);
    if (!names) {
        goto failure;
    }
    const int count = (int)sk_GENERAL_NAME_num(names);
    if (!count) {
        goto failure;
    }

    bool is_valid = false;
    for (int i = 0; i < count; ++i) {
        GENERAL_NAME* entry = sk_GENERAL_NAME_value(names, i);
        if (!entry || entry->type != GEN_DNS) {
            continue;
        }
        unsigned char *ns_name = NULL;
        const int len1 = ASN1_STRING_to_UTF8(&ns_name, entry->d.dNSName);
        if (!ns_name) {
            continue;
        }
        const int len2 = (int)strlen((const char *)ns_name);
        if (len1 != len2) {
            OPENSSL_free(ns_name);
            ns_name = NULL;
            continue;
        }
        if (ns_name && len1 && len2 && (len1 == len2) && strcmp((const char *)ns_name, hostname) == 0) {
            OPENSSL_free(ns_name);
            ns_name = NULL;
            is_valid = true;
            break;
        }
    }

    GENERAL_NAMES_free(names);
    X509_free(cert);
    return is_valid;

failure:
    if (names) GENERAL_NAMES_free(names);
    if (cert) X509_free(cert);
    return false;
}
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto_openssl.h"

pp_crypto_fnt pp_crypto_fnt_openssl(void) {
    pp_crypto_fnt table = {
        .name = "openssl",

        .enc = {
            .init_seed = pp_openssl_crypto_init_seed,
            .aead_create = pp_openssl_crypto_aead_create,
            .aead_free = pp_openssl_crypto_aead_free,
            .cbc_create = pp_openssl_crypto_cbc_create,
            .cbc_free = pp_openssl_crypto_cbc_free,
            .ctr_create = pp_openssl_crypto_ctr_create,
            .ctr_free = pp_openssl_crypto_ctr_free
        },

        .hmac_do = pp_openssl_hmac_do,

        .key_decrypted_from_path = pp_openssl_key_decrypted_from_path,
        .key_decrypted_from_pem = pp_openssl_key_decrypted_from_pem,

        .tls = {
            .create = pp_openssl_tls_create,
            .free = pp_openssl_tls_free,
            .start = pp_openssl_tls_start,
            .is_connected = pp_openssl_tls_is_connected,
            .pull_cipher = pp_openssl_tls_pull_cipher,
            .pull_plain = pp_openssl_tls_pull_plain,
            .put_cipher = pp_openssl_tls_put_cipher,
            .put_plain = pp_openssl_tls_put_plain,
            .ca_md5 = pp_openssl_tls_ca_md5
        }
    };
    return table;
}
