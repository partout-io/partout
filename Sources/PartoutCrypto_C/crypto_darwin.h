/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#include <CommonCrypto/CommonRandom.h>
#include <stdbool.h>
#include <strings.h>
#include "crypto/crypto_base.h"
#include "portable/common.h"

#pragma clang assume_nonnull begin

#define PP_CC_HMAC_MAX_LENGTH (size_t)128
#define PP_CC_AES_BLOCK_SIZE (size_t)kCCBlockSizeAES128

typedef struct {
    CCHmacAlgorithm algorithm;
    size_t length;
} pp_cc_digest;

bool pp_darwin_crypto_init_seed(const uint8_t *src, const size_t len);

pp_crypto_ctx _Nullable pp_darwin_crypto_cbc_create(const char *_Nullable cipher_name,
                                                    const char *digest_name,
                                                    const pp_crypto_keys *_Nullable keys);
void pp_darwin_crypto_cbc_free(pp_crypto_ctx ctx);

pp_crypto_ctx _Nullable pp_darwin_crypto_ctr_create(const char *cipher_name,
                                                    const char *digest_name,
                                                    size_t tag_len,
                                                    size_t payload_len,
                                                    const pp_crypto_keys *_Nullable keys);
void pp_darwin_crypto_ctr_free(pp_crypto_ctx ctx);

static inline
bool pp_cc_digest_by_name(const char *name, pp_cc_digest *digest) {
    pp_assert(name);
    pp_assert(digest);

    if (!strcasecmp(name, "MD5")) {
        digest->algorithm = kCCHmacAlgMD5;
        digest->length = CC_MD5_DIGEST_LENGTH;
        return true;
    }
    if (!strcasecmp(name, "SHA1")) {
        digest->algorithm = kCCHmacAlgSHA1;
        digest->length = CC_SHA1_DIGEST_LENGTH;
        return true;
    }
    if (!strcasecmp(name, "SHA224")) {
        digest->algorithm = kCCHmacAlgSHA224;
        digest->length = CC_SHA224_DIGEST_LENGTH;
        return true;
    }
    if (!strcasecmp(name, "SHA256")) {
        digest->algorithm = kCCHmacAlgSHA256;
        digest->length = CC_SHA256_DIGEST_LENGTH;
        return true;
    }
    if (!strcasecmp(name, "SHA384")) {
        digest->algorithm = kCCHmacAlgSHA384;
        digest->length = CC_SHA384_DIGEST_LENGTH;
        return true;
    }
    if (!strcasecmp(name, "SHA512")) {
        digest->algorithm = kCCHmacAlgSHA512;
        digest->length = CC_SHA512_DIGEST_LENGTH;
        return true;
    }
    return false;
}

static inline
bool pp_cc_aes_key_len_by_name(const char *name, const char *suffix, size_t *key_len) {
    pp_assert(name);
    pp_assert(suffix);
    pp_assert(key_len);

    const size_t suffix_len = strlen(suffix);
    const size_t name_len = strlen(name);
    if (name_len < suffix_len || strcasecmp(name + name_len - suffix_len, suffix)) {
        return false;
    }
    if (!strncasecmp(name, "AES-128-", 8)) {
        *key_len = kCCKeySizeAES128;
        return true;
    }
    if (!strncasecmp(name, "AES-192-", 8)) {
        *key_len = kCCKeySizeAES192;
        return true;
    }
    if (!strncasecmp(name, "AES-256-", 8)) {
        *key_len = kCCKeySizeAES256;
        return true;
    }
    return false;
}

static inline
bool pp_cc_secure_equal(const uint8_t *lhs, const uint8_t *rhs, size_t len) {
    uint8_t diff = 0;
    for (size_t i = 0; i < len; ++i) {
        diff |= lhs[i] ^ rhs[i];
    }
    return diff == 0;
}

static inline
void pp_cc_hmac_update(CCHmacContext *ctx, const void *_Nullable data, size_t len) {
    if (len > 0) {
        pp_assert(data);
        CCHmacUpdate(ctx, data, len);
    }
}

static inline
void pp_cc_hmac(const pp_cc_digest *digest,
                const uint8_t *key, size_t key_len,
                const void *_Nullable data1, size_t data1_len,
                const void *_Nullable data2, size_t data2_len,
                uint8_t *out) {
    pp_assert(digest);
    pp_assert(key);
    pp_assert(out);

    CCHmacContext hmac;
    CCHmacInit(&hmac, digest->algorithm, key, key_len);
    pp_cc_hmac_update(&hmac, data1, data1_len);
    pp_cc_hmac_update(&hmac, data2, data2_len);
    CCHmacFinal(&hmac, out);
}

#pragma clang assume_nonnull end
