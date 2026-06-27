/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <psa/crypto.h>
#include <stddef.h>
#include "portable/common.h"
#include "crypto/hmac.h"

#define PP_MBED_HMAC_MAX_LENGTH (size_t)128

typedef struct {
    psa_algorithm_t algorithm;
    size_t length;
} pp_mbed_digest;

static
char pp_mbed_ascii_upper(char c) {
    if (c >= 'a' && c <= 'z') {
        return (char)(c - ('a' - 'A'));
    }
    return c;
}

static
bool pp_mbed_ascii_equal(const char *lhs, const char *rhs) {
    pp_assert(lhs);
    pp_assert(rhs);

    while (*lhs && *rhs) {
        if (pp_mbed_ascii_upper(*lhs) != pp_mbed_ascii_upper(*rhs)) {
            return false;
        }
        ++lhs;
        ++rhs;
    }
    return *lhs == *rhs;
}

static
bool pp_mbed_init(void) {
    return psa_crypto_init() == PSA_SUCCESS;
}

static
bool pp_mbed_digest_by_name(const char *name, pp_mbed_digest *digest) {
    pp_assert(name);
    pp_assert(digest);

    if (pp_mbed_ascii_equal(name, "MD5")) {
        digest->algorithm = PSA_ALG_MD5;
        digest->length = PSA_HASH_LENGTH(PSA_ALG_MD5);
        return true;
    }
    if (pp_mbed_ascii_equal(name, "SHA1")) {
        digest->algorithm = PSA_ALG_SHA_1;
        digest->length = PSA_HASH_LENGTH(PSA_ALG_SHA_1);
        return true;
    }
    if (pp_mbed_ascii_equal(name, "SHA224")) {
        digest->algorithm = PSA_ALG_SHA_224;
        digest->length = PSA_HASH_LENGTH(PSA_ALG_SHA_224);
        return true;
    }
    if (pp_mbed_ascii_equal(name, "SHA256")) {
        digest->algorithm = PSA_ALG_SHA_256;
        digest->length = PSA_HASH_LENGTH(PSA_ALG_SHA_256);
        return true;
    }
    if (pp_mbed_ascii_equal(name, "SHA384")) {
        digest->algorithm = PSA_ALG_SHA_384;
        digest->length = PSA_HASH_LENGTH(PSA_ALG_SHA_384);
        return true;
    }
    if (pp_mbed_ascii_equal(name, "SHA512")) {
        digest->algorithm = PSA_ALG_SHA_512;
        digest->length = PSA_HASH_LENGTH(PSA_ALG_SHA_512);
        return true;
    }
    return false;
}

static
bool pp_mbed_import_key(psa_key_type_t type,
                        psa_key_usage_t usage,
                        psa_algorithm_t algorithm,
                        const uint8_t *key_bytes,
                        size_t key_len,
                        mbedtls_svc_key_id_t *key) {
    pp_assert(key_bytes);
    pp_assert(key);

    if (!pp_mbed_init()) {
        return false;
    }

    psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attributes, type);
    psa_set_key_bits(&attributes, 8 * key_len);
    psa_set_key_usage_flags(&attributes, usage);
    psa_set_key_algorithm(&attributes, algorithm);
    const psa_status_t status = psa_import_key(&attributes, key_bytes, key_len, key);
    psa_reset_key_attributes(&attributes);
    return status == PSA_SUCCESS;
}

static
bool pp_mbed_hmac(const pp_mbed_digest *digest,
                  const uint8_t *key_bytes,
                  size_t key_len,
                  const void *data1,
                  size_t data1_len,
                  const void *data2,
                  size_t data2_len,
                  uint8_t *out,
                  size_t out_len) {
    pp_assert(digest);
    pp_assert(key_bytes);
    pp_assert(out);
    pp_assert(out_len >= digest->length);

    const psa_algorithm_t algorithm = PSA_ALG_HMAC(digest->algorithm);
    mbedtls_svc_key_id_t key = MBEDTLS_SVC_KEY_ID_INIT;
    if (!pp_mbed_import_key(PSA_KEY_TYPE_HMAC,
                            PSA_KEY_USAGE_SIGN_MESSAGE,
                            algorithm,
                            key_bytes,
                            key_len,
                            &key)) {
        return false;
    }

    psa_mac_operation_t operation = PSA_MAC_OPERATION_INIT;
    psa_status_t status = psa_mac_sign_setup(&operation, key, algorithm);
    if (status == PSA_SUCCESS && data1_len > 0) {
        pp_assert(data1);
        status = psa_mac_update(&operation, data1, data1_len);
    }
    if (status == PSA_SUCCESS && data2_len > 0) {
        pp_assert(data2);
        status = psa_mac_update(&operation, data2, data2_len);
    }
    size_t mac_len = 0;
    if (status == PSA_SUCCESS) {
        status = psa_mac_sign_finish(&operation, out, out_len, &mac_len);
    }
    if (status != PSA_SUCCESS) {
        (void)psa_mac_abort(&operation);
    }
    (void)psa_destroy_key(key);

    return status == PSA_SUCCESS && mac_len == digest->length;
}

static inline
size_t pp_mbed_hmac_do(pp_hmac_ctx *ctx) {
    pp_assert(ctx);
    pp_assert(ctx->dst_len >= PP_MBED_HMAC_MAX_LENGTH);

    pp_mbed_digest digest;
    if (!pp_mbed_digest_by_name(ctx->digest_name, &digest)) {
        return 0;
    }

    if (!pp_mbed_hmac(&digest,
                      ctx->secret,
                      ctx->secret_len,
                      ctx->data,
                      ctx->data_len,
                      NULL,
                      0,
                      ctx->dst,
                      ctx->dst_len)) {
        return 0;
    }
    return digest.length;
}
