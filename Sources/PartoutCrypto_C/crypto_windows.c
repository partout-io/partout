/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/crypto.h"
#include "crypto_windows.h"

bool pp_windows_crypto_init_seed(const uint8_t *src, const size_t len) {
    (void)src;
    (void)len;
    return true;
}
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include <bcrypt.h>
#include <string.h>
#include "crypto_windows.h"

#pragma comment(lib, "bcrypt.lib")

typedef struct {
    pp_crypto crypto;

    // cipher
    BCRYPT_ALG_HANDLE hAlg;
    BCRYPT_KEY_HANDLE hKeyEnc;
    BCRYPT_KEY_HANDLE hKeyDec;
    uint8_t *_Nonnull iv_enc;
    uint8_t *_Nonnull iv_dec;
    size_t id_len;
    UCHAR tag[128]; // max length
} pp_crypto_aead;

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

    if (ctx->hKeyEnc) {
        BCryptDestroyKey(ctx->hKeyEnc);
        ctx->hKeyEnc = NULL;
    }
    PP_CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
        ctx->hAlg,
        &ctx->hKeyEnc,
        NULL, 0,
        (PUCHAR)cipher_key->bytes,
        (ULONG)ctx->crypto.meta.cipher_key_len,
        0
    ))
    memset(ctx->iv_enc, 0, ctx->id_len);
    memcpy(ctx->iv_enc + ctx->id_len, hmac_key->bytes, ctx->crypto.meta.cipher_iv_len - ctx->id_len);
}

static
size_t aead_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->hKeyEnc);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);

    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t tag_len = ctx->crypto.meta.tag_len;
    ULONG cbResult = 0;
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO authInfo;

    BCRYPT_INIT_AUTH_MODE_INFO(authInfo);
    memcpy(ctx->iv_enc, flags->iv, (size_t)MIN(flags->iv_len, cipher_iv_len));
    authInfo.pbNonce = ctx->iv_enc;
    authInfo.cbNonce = (ULONG)cipher_iv_len;
    authInfo.pbAuthData = (PUCHAR)flags->ad;
    authInfo.cbAuthData = (ULONG)flags->ad_len;
    authInfo.pbTag = ctx->tag;
    authInfo.cbTag = (ULONG)tag_len;

    PP_CRYPTO_CHECK(BCryptEncrypt(
        ctx->hKeyEnc,
        (PUCHAR)in, (ULONG)in_len,
        &authInfo,
        NULL, 0,
        out + tag_len,
        (ULONG)(out_buf_len - tag_len),
        &cbResult,
        0
    ))
    memcpy(out, ctx->tag, tag_len);

    const size_t out_len = tag_len + cbResult;
    return out_len;
}

static
void aead_configure_decrypt(void *vctx,
                             const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);
    pp_assert(hmac_key);

    if (ctx->hKeyDec) {
        BCryptDestroyKey(ctx->hKeyDec);
        ctx->hKeyDec = NULL;
    }
    PP_CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
        ctx->hAlg,
        &ctx->hKeyDec,
        NULL, 0,
        (PUCHAR)cipher_key->bytes,
        (ULONG)ctx->crypto.meta.cipher_key_len,
        0
    ))
    memset(ctx->iv_dec, 0, ctx->id_len);
    memcpy(ctx->iv_dec + ctx->id_len, hmac_key->bytes, ctx->crypto.meta.cipher_iv_len - ctx->id_len);
}

static
size_t aead_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    pp_crypto_aead *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->hKeyDec);
    pp_assert(flags);
    pp_assert(flags->ad_len >= ctx->id_len);

    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t tag_len = ctx->crypto.meta.tag_len;
    ULONG cbResult = 0;
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO authInfo;

    BCRYPT_INIT_AUTH_MODE_INFO(authInfo);
    memcpy(ctx->iv_dec, flags->iv, (size_t)MIN(flags->iv_len, cipher_iv_len));
    authInfo.pbNonce = ctx->iv_dec;
    authInfo.cbNonce = (ULONG)cipher_iv_len;
    authInfo.pbAuthData = (PUCHAR)flags->ad;
    authInfo.cbAuthData = (ULONG)flags->ad_len;
    authInfo.pbTag = (PUCHAR)in;
    authInfo.cbTag = (ULONG)tag_len;

    PP_CRYPTO_CHECK(BCryptDecrypt(
        ctx->hKeyDec,
        (PUCHAR)(in + tag_len),
        (ULONG)(in_len - tag_len),
        &authInfo,
        NULL, 0,
        out, out_buf_len,
        &cbResult,
        0
    ))

    const size_t out_len = cbResult;
    return out_len;
}

// MARK: -

pp_crypto_ctx pp_windows_crypto_aead_create(const char *cipher_name,
                                            size_t tag_len, size_t id_len,
                                            const pp_crypto_keys *keys) {
    pp_assert(cipher_name);

    size_t cipher_key_len;
    if (!_stricmp(cipher_name, "AES-128-GCM")) {
        cipher_key_len = 16;
    } else if (!_stricmp(cipher_name, "AES-256-GCM")) {
        cipher_key_len = 32;
    } else {
        return NULL;
    }

    pp_crypto_aead *ctx = pp_alloc(sizeof(pp_crypto_aead));
    PP_CRYPTO_CHECK_CREATE(BCryptOpenAlgorithmProvider(
        &ctx->hAlg,
        BCRYPT_AES_ALGORITHM,
        NULL,
        0
    ));
    PP_CRYPTO_CHECK_CREATE(BCryptSetProperty(
        ctx->hAlg,
        BCRYPT_CHAINING_MODE,
        (PUCHAR)BCRYPT_CHAIN_MODE_GCM,
        (ULONG)sizeof(BCRYPT_CHAIN_MODE_GCM),
        0
    ));

    // no longer fails

    ctx->crypto.meta.cipher_key_len = cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = 12; // standard GCM IV size
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
    if (ctx->hAlg) BCryptCloseAlgorithmProvider(ctx->hAlg, 0);
    pp_free(ctx);
    return NULL;
}

void pp_windows_crypto_aead_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_aead *ctx = (pp_crypto_aead *)vctx;

    if (ctx->hKeyEnc) BCryptDestroyKey(ctx->hKeyEnc);
    if (ctx->hKeyDec) BCryptDestroyKey(ctx->hKeyDec);
    BCryptCloseAlgorithmProvider(ctx->hAlg, 0);
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

#include "portable/common.h"
#include <bcrypt.h>
#include <string.h>
#include "crypto_windows.h"

#pragma comment(lib, "bcrypt.lib")

#define IVMaxLength (size_t)16
#define HMACMaxLength (size_t)128

typedef struct {
    pp_crypto crypto;

    // cipher
    BCRYPT_ALG_HANDLE hAlgCipher;
    BCRYPT_KEY_HANDLE hKeyEnc;
    BCRYPT_KEY_HANDLE hKeyDec;

    // HMAC
    BCRYPT_ALG_HANDLE hAlgHmac;
    pp_zd *_Nonnull hmac_key_enc;
    pp_zd *_Nonnull hmac_key_dec;
    UCHAR buffer_iv[IVMaxLength];
    UCHAR buffer_hmac[HMACMaxLength];
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

    if (ctx->hKeyEnc) {
        BCryptDestroyKey(ctx->hKeyEnc);
        ctx->hKeyEnc = NULL;
    }
    if (ctx->hAlgCipher) {
        PP_CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
            ctx->hAlgCipher,
            &ctx->hKeyEnc,
            NULL, 0,
            (PUCHAR)cipher_key->bytes,
            (ULONG)ctx->crypto.meta.cipher_key_len,
            0
        ))
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
    pp_assert(ctx->hmac_key_enc);

    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t hmac_key_len = ctx->crypto.meta.hmac_key_len;
    uint8_t *out_iv = out + digest_len;
    uint8_t *out_encrypted = out_iv + cipher_iv_len;
    ULONG enc_len = 0;

    if (ctx->hAlgCipher) {
        if (!flags || !flags->for_testing) {
            PP_CRYPTO_CHECK(BCryptGenRandom(
                NULL,
                out_iv,
                (ULONG)cipher_iv_len,
                BCRYPT_USE_SYSTEM_PREFERRED_RNG
            ))
        }

        // do NOT use out_iv directly because BCryptEncrypt has side-effect
        memcpy(ctx->buffer_iv, out_iv, cipher_iv_len);

        PP_CRYPTO_CHECK(BCryptEncrypt(
            ctx->hKeyEnc,
            (PUCHAR)in, (ULONG)in_len,
            NULL,
            ctx->buffer_iv, (ULONG)cipher_iv_len,
            out_encrypted, out_buf_len - (out_encrypted - out),
            &enc_len,
            BCRYPT_BLOCK_PADDING
        ))
    } else {
        pp_assert(out_encrypted == out_iv);
        memcpy(out_encrypted, in, in_len);
        enc_len = in_len;
    }

    BCRYPT_HASH_HANDLE hHmac = NULL;
    PP_CRYPTO_CHECK_MAC(BCryptCreateHash(
        ctx->hAlgHmac,
        &hHmac,
        NULL, 0,
        ctx->hmac_key_enc->bytes, (ULONG)hmac_key_len,
        0
    ))
    PP_CRYPTO_CHECK_MAC(BCryptHashData(hHmac, out_iv, (ULONG)(enc_len + cipher_iv_len), 0))
    PP_CRYPTO_CHECK_MAC(BCryptFinishHash(hHmac, out, (ULONG)digest_len, 0))
    BCryptDestroyHash(hHmac);

    const size_t out_len = enc_len + cipher_iv_len + digest_len;
    return out_len;
}

static
void cbc_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);

    if (ctx->hKeyDec) {
        BCryptDestroyKey(ctx->hKeyDec);
        ctx->hKeyDec = NULL;
    }
    if (ctx->hAlgCipher) {
        PP_CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
            ctx->hAlgCipher,
            &ctx->hKeyDec,
            NULL, 0,
            (PUCHAR)cipher_key->bytes,
            (ULONG)ctx->crypto.meta.cipher_key_len,
            0
        ))
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
    pp_assert(ctx->hmac_key_dec);

    const size_t cipher_iv_len = ctx->crypto.meta.cipher_iv_len;
    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t hmac_key_len = ctx->crypto.meta.hmac_key_len;
    const uint8_t *iv = in + digest_len;
    const uint8_t *encrypted = in + digest_len + cipher_iv_len;

    BCRYPT_HASH_HANDLE hHmac = NULL;
    PP_CRYPTO_CHECK(BCryptCreateHash(
        ctx->hAlgHmac,
        &hHmac,
        NULL, 0,
        ctx->hmac_key_dec->bytes, (ULONG)hmac_key_len,
        0
    ))
    PP_CRYPTO_CHECK(BCryptHashData(hHmac, (PUCHAR)(in + digest_len), (ULONG)(in_len - digest_len), 0))
    PP_CRYPTO_CHECK(BCryptFinishHash(hHmac, ctx->buffer_hmac, (ULONG)digest_len, 0))
    BCryptDestroyHash(hHmac);

    if (memcmp(ctx->buffer_hmac, in, digest_len) != 0) {
        PP_CRYPTO_SET_ERROR(PPCryptoErrorHMAC)
        return 0;
    }

    ULONG out_len = 0;
    if (ctx->hAlgCipher) {
        PP_CRYPTO_CHECK(BCryptDecrypt(
            ctx->hKeyDec,
            (PUCHAR)encrypted, (ULONG)(in_len - digest_len - cipher_iv_len),
            NULL,
            (PUCHAR)iv, (ULONG)cipher_iv_len,
            out, out_buf_len,
            &out_len,
            BCRYPT_BLOCK_PADDING
        ))
    } else {
        memcpy(out, in + digest_len, in_len - digest_len);
        out_len = in_len - digest_len;
    }
    return out_len;
}

static
bool cbc_verify(void *vctx, const uint8_t *in, size_t in_len, pp_crypto_error_code *error) {
    pp_crypto_cbc *ctx = vctx;
    pp_assert(ctx);

    const size_t digest_len = ctx->crypto.meta.digest_len;
    const size_t hmac_key_len = ctx->crypto.meta.hmac_key_len;
    BCRYPT_HASH_HANDLE hHmac = NULL;
    PP_CRYPTO_CHECK_MAC(BCryptCreateHash(
        ctx->hAlgHmac,
        &hHmac,
        NULL, 0,
        ctx->hmac_key_dec->bytes, (ULONG)hmac_key_len,
        0
    ))
    PP_CRYPTO_CHECK_MAC(BCryptHashData(hHmac, (PUCHAR)(in + digest_len), (ULONG)(in_len - digest_len), 0))
    PP_CRYPTO_CHECK_MAC(BCryptFinishHash(hHmac, ctx->buffer_hmac, (ULONG)digest_len, 0))
    BCryptDestroyHash(hHmac);

    if (memcmp(ctx->buffer_hmac, in, digest_len) != 0) {
        PP_CRYPTO_SET_ERROR(PPCryptoErrorHMAC)
        return false;
    }
    return true;
}

// MARK: -

pp_crypto_ctx pp_windows_crypto_cbc_create(const char *cipher_name,
                                           const char *digest_name,
                                           const pp_crypto_keys *keys) {
    pp_assert(digest_name);

    size_t cipher_key_len;
    size_t cipher_iv_len;
    LPCWSTR hmac_alg_id;
    size_t hmac_key_len;

    if (cipher_name) {
        if (!_stricmp(cipher_name, "AES-128-CBC")) {
            cipher_key_len = 16;
            cipher_iv_len = 16;
        } else if (!_stricmp(cipher_name, "AES-256-CBC")) {
            cipher_key_len = 32;
            cipher_iv_len = 16;
        } else {
            return NULL;
        }
    } else {
        cipher_key_len = 0;
        cipher_iv_len = 0;
    }
    if (!_stricmp(digest_name, "SHA1")) {
        hmac_alg_id = BCRYPT_SHA1_ALGORITHM;
        hmac_key_len = 20;
    } else if (!_stricmp(digest_name, "SHA256")) {
        hmac_alg_id = BCRYPT_SHA256_ALGORITHM;
        hmac_key_len = 32;
    } else if (!_stricmp(digest_name, "SHA512")) {
        hmac_alg_id = BCRYPT_SHA512_ALGORITHM;
        hmac_key_len = 64;
    } else {
        return NULL;
    }

    pp_crypto_cbc *ctx = pp_alloc(sizeof(pp_crypto_cbc));

    if (cipher_name) {
        PP_CRYPTO_CHECK_CREATE(BCryptOpenAlgorithmProvider(
            &ctx->hAlgCipher,
            BCRYPT_AES_ALGORITHM,
            NULL,
            0
        ));
        PP_CRYPTO_CHECK_CREATE(BCryptSetProperty(
            ctx->hAlgCipher,
            BCRYPT_CHAINING_MODE,
            (PUCHAR)BCRYPT_CHAIN_MODE_CBC,
            (ULONG)sizeof(BCRYPT_CHAIN_MODE_CBC),
            0
        ));
    } else {
        ctx->hAlgCipher = NULL;
    }
    PP_CRYPTO_CHECK_CREATE(BCryptOpenAlgorithmProvider(
        &ctx->hAlgHmac,
        hmac_alg_id,
        NULL,
        BCRYPT_ALG_HANDLE_HMAC_FLAG
    ));

    // no longer fails

    ctx->crypto.meta.cipher_key_len = cipher_key_len;
    ctx->crypto.meta.cipher_iv_len = cipher_iv_len;
    ctx->crypto.meta.hmac_key_len = hmac_key_len;
    ctx->crypto.meta.digest_len = hmac_key_len;
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
    if (ctx->hAlgCipher) BCryptCloseAlgorithmProvider(ctx->hAlgCipher, 0);
    pp_free(ctx);
    return NULL;
}

void pp_windows_crypto_cbc_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_cbc *ctx = (pp_crypto_cbc *)vctx;

    if (ctx->hKeyEnc) BCryptDestroyKey(ctx->hKeyEnc);
    if (ctx->hKeyDec) BCryptDestroyKey(ctx->hKeyDec);
    if (ctx->hAlgCipher) BCryptCloseAlgorithmProvider(ctx->hAlgCipher, 0);

    if (ctx->hmac_key_enc) pp_zd_free(ctx->hmac_key_enc);
    if (ctx->hmac_key_dec) pp_zd_free(ctx->hmac_key_dec);
    BCryptCloseAlgorithmProvider(ctx->hAlgHmac, 0);
    pp_zero(ctx->buffer_iv, sizeof(ctx->buffer_iv));
    pp_zero(ctx->buffer_hmac, sizeof(ctx->buffer_hmac));

    pp_free(ctx);
} 
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include <bcrypt.h>
#include <string.h>
#include "crypto_windows.h"

#pragma comment(lib, "bcrypt.lib")

typedef struct {
    pp_crypto crypto;

    // cipher
    BCRYPT_ALG_HANDLE hAlgCipher;
    BCRYPT_KEY_HANDLE hKeyEnc;
    BCRYPT_KEY_HANDLE hKeyDec;
    size_t ns_tag_len;
    size_t payload_len;

    // HMAC
    pp_zd *_Nonnull hmac_key_enc;
    pp_zd *_Nonnull hmac_key_dec;
    uint8_t *_Nonnull buffer_hmac;
} pp_crypto_ctr;

static inline
void ctr_increment(uint8_t *counter, size_t len) {
    for (int i = (int)len - 1; i >= 0; --i) {
        if (++counter[i] != 0) break;
    }
}

static
size_t ctr_encryption_capacity(const void *vctx, size_t len) {
    const pp_crypto_ctr *ctx = (const pp_crypto_ctr *)vctx;
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

    if (ctx->hKeyEnc) {
        BCryptDestroyKey(ctx->hKeyEnc);
        ctx->hKeyEnc = NULL;
    }
    PP_CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
        ctx->hAlgCipher,
        &ctx->hKeyEnc,
        NULL, 0,
        (PUCHAR)cipher_key->bytes,
        (ULONG)ctx->crypto.meta.cipher_key_len,
        0
    ))
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
    (void)out_buf_len;
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->hKeyEnc);
    pp_assert(ctx->hmac_key_enc);
    pp_assert(flags);

    uint8_t *out_encrypted = out + ctx->ns_tag_len;
    size_t block_size = ctx->crypto.meta.cipher_iv_len;
    size_t nblocks = (in_len + block_size - 1) / block_size;
    uint8_t counter[32] = {0};
    uint8_t ecb_out[32] = {0};
    size_t offset = 0;

    // HMAC (SHA256)
    BCRYPT_ALG_HANDLE hAlgHmac = NULL;
    BCRYPT_HASH_HANDLE hHmac = NULL;
    PP_CRYPTO_CHECK_MAC_ALG(BCryptOpenAlgorithmProvider(
        &hAlgHmac,
        BCRYPT_SHA256_ALGORITHM,
        NULL,
        BCRYPT_ALG_HANDLE_HMAC_FLAG
    ))
    PP_CRYPTO_CHECK_MAC_ALG(BCryptCreateHash(
        hAlgHmac,
        &hHmac,
        NULL, 0,
        ctx->hmac_key_enc->bytes, (ULONG)ctx->crypto.meta.hmac_key_len,
        0
    ))
    PP_CRYPTO_CHECK_MAC_ALG(BCryptHashData(hHmac, (PUCHAR)flags->ad, (ULONG)flags->ad_len, 0))
    PP_CRYPTO_CHECK_MAC_ALG(BCryptHashData(hHmac, (PUCHAR)in, (ULONG)in_len, 0))
    PP_CRYPTO_CHECK_MAC_ALG(BCryptFinishHash(hHmac, out, (ULONG)ctx->ns_tag_len, 0))
    BCryptDestroyHash(hHmac);
    BCryptCloseAlgorithmProvider(hAlgHmac, 0);

    // CTR mode using ECB primitive
    memcpy(counter, out, block_size); // Use tag as IV/counter
    for (size_t b = 0; b < nblocks; ++b) {
        ULONG ecb_len = 0;
        PP_CRYPTO_CHECK(BCryptEncrypt(
            ctx->hKeyEnc,
            counter, (ULONG)block_size,
            NULL,
            NULL, 0,
            ecb_out, (ULONG)block_size,
            &ecb_len,
            0
        ))
        size_t chunk = (in_len - offset > block_size) ? block_size : (in_len - offset);
        for (size_t i = 0; i < chunk; ++i) {
            out_encrypted[offset + i] = in[offset + i] ^ ecb_out[i];
        }
        offset += chunk;
        ctr_increment(counter, block_size);
    }
    const size_t out_len = ctx->ns_tag_len + in_len;
    return out_len;
}

static
void ctr_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(hmac_key && hmac_key->length >= ctx->crypto.meta.hmac_key_len);
    pp_assert(cipher_key && cipher_key->length >= ctx->crypto.meta.cipher_key_len);

    if (ctx->hKeyDec) {
        BCryptDestroyKey(ctx->hKeyDec);
        ctx->hKeyDec = NULL;
    }
    PP_CRYPTO_ASSERT(BCryptGenerateSymmetricKey(
        ctx->hAlgCipher,
        &ctx->hKeyDec,
        NULL, 0,
        (PUCHAR)cipher_key->bytes,
        (ULONG)ctx->crypto.meta.cipher_key_len,
        0
    ))
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
    (void)out_buf_len;
    pp_crypto_ctr *ctx = vctx;
    pp_assert(ctx);
    pp_assert(ctx->hKeyDec);
    pp_assert(ctx->hmac_key_dec);
    pp_assert(flags);

    const uint8_t *iv = in;
    const uint8_t *encrypted = in + ctx->ns_tag_len;
    size_t enc_len = in_len - ctx->ns_tag_len;
    size_t block_size = ctx->crypto.meta.cipher_iv_len;
    size_t nblocks = (enc_len + block_size - 1) / block_size;
    uint8_t counter[32] = {0};
    uint8_t ecb_out[32] = {0};
    size_t offset = 0;

    // CTR mode using ECB primitive
    memcpy(counter, iv, block_size);
    for (size_t b = 0; b < nblocks; ++b) {
        ULONG ecb_len = 0;
        PP_CRYPTO_CHECK(BCryptEncrypt(
            ctx->hKeyDec,
            counter, (ULONG)block_size,
            NULL,
            NULL, 0,
            ecb_out, (ULONG)block_size,
            &ecb_len,
            0
        ))
        size_t chunk = (enc_len - offset > block_size) ? block_size : (enc_len - offset);
        for (size_t i = 0; i < chunk; ++i) {
            out[offset + i] = encrypted[offset + i] ^ ecb_out[i];
        }
        offset += chunk;
        ctr_increment(counter, block_size);
    }

    size_t out_len = enc_len;

    // HMAC verify
    BCRYPT_ALG_HANDLE hAlgHmac = NULL;
    BCRYPT_HASH_HANDLE hHmac = NULL;
    PP_CRYPTO_CHECK_MAC_ALG(BCryptOpenAlgorithmProvider(
        &hAlgHmac,
        BCRYPT_SHA256_ALGORITHM,
        NULL,
        BCRYPT_ALG_HANDLE_HMAC_FLAG
    ))
    PP_CRYPTO_CHECK_MAC_ALG(BCryptCreateHash(
        hAlgHmac,
        &hHmac,
        NULL, 0,
        ctx->hmac_key_dec->bytes, (ULONG)ctx->crypto.meta.hmac_key_len,
        0
    ))
    PP_CRYPTO_CHECK_MAC_ALG(BCryptHashData(hHmac, (PUCHAR)flags->ad, (ULONG)flags->ad_len, 0))
    PP_CRYPTO_CHECK_MAC_ALG(BCryptHashData(hHmac, out, out_len, 0))
    PP_CRYPTO_CHECK_MAC_ALG(BCryptFinishHash(hHmac, ctx->buffer_hmac, (ULONG)ctx->ns_tag_len, 0))
    BCryptDestroyHash(hHmac);
    BCryptCloseAlgorithmProvider(hAlgHmac, 0);

    if (memcmp(ctx->buffer_hmac, in, ctx->ns_tag_len) != 0) {
        PP_CRYPTO_SET_ERROR(PPCryptoErrorHMAC)
        return 0;
    }
    return out_len;
}

// MARK: -

pp_crypto_ctx pp_windows_crypto_ctr_create(const char *cipher_name,
                                           const char *digest_name,
                                           size_t tag_len, size_t payload_len,
                                           const pp_crypto_keys *keys) {
    pp_assert(cipher_name && digest_name);

    // only AES-CTR and HMAC-SHA256 supported
    if (_stricmp(cipher_name, "AES-128-CTR")) {
        return NULL;
    }
    if (_stricmp(digest_name, "SHA256")) {
        return NULL;
    }

    pp_crypto_ctr *ctx = pp_alloc(sizeof(pp_crypto_ctr));

    // no chaining mode, use ECB for manual CTR
    PP_CRYPTO_CHECK_CREATE(BCryptOpenAlgorithmProvider(
        &ctx->hAlgCipher,
        BCRYPT_AES_ALGORITHM,
        NULL,
        0
    ));

    // no longer fails

    ctx->buffer_hmac = pp_alloc(tag_len);

    ctx->crypto.meta.cipher_key_len = 16; // AES-128
    ctx->crypto.meta.cipher_iv_len = 16;  // AES block size
    ctx->crypto.meta.hmac_key_len = 32;   // SHA256 output size
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
    if (ctx->hAlgCipher) BCryptCloseAlgorithmProvider(ctx->hAlgCipher, 0);
    pp_free(ctx);
    return NULL;
}

void pp_windows_crypto_ctr_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    pp_crypto_ctr *ctx = (pp_crypto_ctr *)vctx;

    if (ctx->hKeyEnc) BCryptDestroyKey(ctx->hKeyEnc);
    if (ctx->hKeyDec) BCryptDestroyKey(ctx->hKeyDec);
    if (ctx->hmac_key_enc) pp_zd_free(ctx->hmac_key_enc);
    if (ctx->hmac_key_dec) pp_zd_free(ctx->hmac_key_dec);

    BCryptCloseAlgorithmProvider(ctx->hAlgCipher, 0);
    pp_zero(ctx->buffer_hmac, ctx->ns_tag_len);
    pp_free(ctx->buffer_hmac);

    pp_free(ctx);
} 
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "hmac_mbedtls.h"

size_t pp_hmac_do(pp_hmac_ctx *ctx) {
    return pp_mbed_hmac_do(ctx);
}
/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "crypto/function_table.h"
#include "crypto_windows.h"

pp_crypto_fnt pp_crypto_fnt_native(void) {
    const pp_crypto_enc_fnt enc = {
        pp_windows_crypto_init_seed,

        pp_windows_crypto_aead_create,
        pp_windows_crypto_aead_free,

        pp_windows_crypto_cbc_create,
        pp_windows_crypto_cbc_free,

        pp_windows_crypto_ctr_create,
        pp_windows_crypto_ctr_free
    };
    pp_crypto_fnt table = pp_crypto_fnt_mbedtls();
    table.name = "native-windows";
    table.enc = enc;
    return table;
}
