/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <windows.h>
#include <bcrypt.h>
#include <string.h>
#include "portable/common.h"
#include "crypto/crypto_ctr.h"
#include "crypto/windows/macros.h"

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
size_t local_encryption_capacity(const void *vctx, size_t len) {
    const pp_crypto_ctr *ctx = (const pp_crypto_ctr *)vctx;
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
size_t local_encrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
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
void local_configure_decrypt(void *vctx, const pp_zd *cipher_key, const pp_zd *hmac_key) {
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
size_t local_decrypt(void *vctx,
                     uint8_t *out, size_t out_buf_len,
                     const uint8_t *in, size_t in_len,
                     const pp_crypto_flags *flags, pp_crypto_error_code *error) {
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

pp_crypto_ctx pp_crypto_ctr_create(const char *cipher_name, const char *digest_name,
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
    if (ctx->hAlgCipher) BCryptCloseAlgorithmProvider(ctx->hAlgCipher, 0);
    pp_free(ctx);
    return NULL;
}

void pp_crypto_ctr_free(pp_crypto_ctx vctx) {
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
