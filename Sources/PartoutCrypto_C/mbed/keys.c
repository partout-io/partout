/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <mbedtls/asn1write.h>
#include <mbedtls/oid.h>
#include <mbedtls/pem.h>
#include <mbedtls/pk.h>
#include <mbedtls/version.h>
#include <psa/crypto.h>
#include "portable/common.h"
#include "crypto/keys.h"

#define PP_MBED_DER_BUFFER_INITIAL 4096
#define PP_MBED_DER_BUFFER_MAX (256 * 1024)
#define PP_MBED_OID_PKCS1_RSA (MBEDTLS_OID_PKCS1 "\x01")
#define PP_MBED_PEM_BEGIN_PRIVATE_KEY "-----BEGIN PRIVATE KEY-----\n"
#define PP_MBED_PEM_END_PRIVATE_KEY "-----END PRIVATE KEY-----\n"

static
bool pp_key_init_psa(void) {
    return psa_crypto_init() == PSA_SUCCESS;
}

static
bool pp_key_is_rsa(const mbedtls_pk_context *key) {
#if MBEDTLS_VERSION_MAJOR >= 4
    return PSA_KEY_TYPE_IS_RSA(mbedtls_pk_get_key_type(key));
#else
    return mbedtls_pk_get_type(key) == MBEDTLS_PK_RSA;
#endif
}

static
int pp_key_der_from_key(const mbedtls_pk_context *key,
                        unsigned char **out,
                        size_t *out_len) {
    size_t buf_len = PP_MBED_DER_BUFFER_INITIAL;

    while (buf_len <= PP_MBED_DER_BUFFER_MAX) {
        unsigned char *buf = pp_alloc(buf_len);
        const int ret = mbedtls_pk_write_key_der(key, buf, buf_len);
        if (ret >= 0) {
            *out_len = (size_t)ret;
            *out = pp_alloc(*out_len);
            memcpy(*out, buf + buf_len - *out_len, *out_len);
            pp_zero(buf, buf_len);
            pp_free(buf);
            return 0;
        }

        pp_zero(buf, buf_len);
        pp_free(buf);
        if (ret != MBEDTLS_ERR_ASN1_BUF_TOO_SMALL &&
            ret != PSA_ERROR_BUFFER_TOO_SMALL) {
            return ret;
        }
        buf_len *= 2;
    }

    return MBEDTLS_ERR_ASN1_BUF_TOO_SMALL;
}

static
int pp_key_pkcs8_der_from_rsa_der(unsigned char **out,
                                  size_t *out_len,
                                  const unsigned char *rsa_der,
                                  size_t rsa_der_len) {
    const size_t buf_len = rsa_der_len + 128;
    unsigned char *buf = pp_alloc(buf_len);
    unsigned char *p = buf + buf_len;
    size_t len = 0;
    int ret;

    ret = mbedtls_asn1_write_octet_string(&p, buf, rsa_der, rsa_der_len);
    if (ret < 0) goto failure;
    len += (size_t)ret;

    ret = mbedtls_asn1_write_algorithm_identifier(
        &p,
        buf,
        PP_MBED_OID_PKCS1_RSA,
        sizeof(PP_MBED_OID_PKCS1_RSA) - 1,
        0
    );
    if (ret < 0) goto failure;
    len += (size_t)ret;

    ret = mbedtls_asn1_write_int(&p, buf, 0);
    if (ret < 0) goto failure;
    len += (size_t)ret;

    ret = mbedtls_asn1_write_len(&p, buf, len);
    if (ret < 0) goto failure;
    len += (size_t)ret;

    ret = mbedtls_asn1_write_tag(
        &p,
        buf,
        MBEDTLS_ASN1_CONSTRUCTED | MBEDTLS_ASN1_SEQUENCE
    );
    if (ret < 0) goto failure;
    len += (size_t)ret;

    *out_len = len;
    *out = pp_alloc(*out_len);
    memcpy(*out, p, *out_len);
    pp_zero(buf, buf_len);
    pp_free(buf);
    return 0;

failure:
    pp_zero(buf, buf_len);
    pp_free(buf);
    return ret;
}

static
char *pp_key_pem_from_der(const unsigned char *der, size_t der_len) {
    size_t pem_len = 0;
    int ret = mbedtls_pem_write_buffer(
        PP_MBED_PEM_BEGIN_PRIVATE_KEY,
        PP_MBED_PEM_END_PRIVATE_KEY,
        der,
        der_len,
        NULL,
        0,
        &pem_len
    );
    if (ret == 0 || pem_len == 0) {
        return NULL;
    }

    unsigned char *pem = pp_alloc(pem_len);
    ret = mbedtls_pem_write_buffer(
        PP_MBED_PEM_BEGIN_PRIVATE_KEY,
        PP_MBED_PEM_END_PRIVATE_KEY,
        der,
        der_len,
        pem,
        pem_len,
        &pem_len
    );
    if (ret != 0) {
        pp_zero(pem, pem_len);
        pp_free(pem);
        return NULL;
    }

    return (char *)pem;
}

static
char *pp_key_pem_from_key(const mbedtls_pk_context *key) {
    if (pp_key_is_rsa(key)) {
        unsigned char *rsa_der = NULL;
        size_t rsa_der_len = 0;
        int ret = pp_key_der_from_key(key, &rsa_der, &rsa_der_len);
        if (ret != 0) {
            return NULL;
        }

        unsigned char *pkcs8_der = NULL;
        size_t pkcs8_der_len = 0;
        ret = pp_key_pkcs8_der_from_rsa_der(
            &pkcs8_der,
            &pkcs8_der_len,
            rsa_der,
            rsa_der_len
        );
        pp_zero(rsa_der, rsa_der_len);
        pp_free(rsa_der);
        if (ret != 0) {
            return NULL;
        }

        char *pem = pp_key_pem_from_der(pkcs8_der, pkcs8_der_len);
        pp_zero(pkcs8_der, pkcs8_der_len);
        pp_free(pkcs8_der);
        return pem;
    }

    size_t pem_len = PP_MBED_DER_BUFFER_INITIAL;
    while (pem_len <= PP_MBED_DER_BUFFER_MAX) {
        unsigned char *pem = pp_alloc(pem_len);
        const int ret = mbedtls_pk_write_key_pem(key, pem, pem_len);
        if (ret == 0) {
            return (char *)pem;
        }

        pp_zero(pem, pem_len);
        pp_free(pem);
        if (ret != MBEDTLS_ERR_ASN1_BUF_TOO_SMALL &&
            ret != PSA_ERROR_BUFFER_TOO_SMALL) {
            return NULL;
        }
        pem_len *= 2;
    }

    return NULL;
}

static
char *pp_key_decrypted_from_buffer(const char *pem, const char *passphrase) {
    if (!pp_key_init_psa()) {
        return NULL;
    }

    mbedtls_pk_context key;
    mbedtls_pk_init(&key);

    const size_t passphrase_len = strlen(passphrase);
    const int ret = mbedtls_pk_parse_key(
        &key,
        (const unsigned char *)pem,
        strlen(pem) + 1,
        passphrase_len ? (const unsigned char *)passphrase : NULL,
        passphrase_len
    );
    if (ret != 0) {
        mbedtls_pk_free(&key);
        return NULL;
    }

    char *decrypted = pp_key_pem_from_key(&key);
    mbedtls_pk_free(&key);
    return decrypted;
}

char *pp_mbed_key_decrypted_from_path(const char *path, const char *passphrase) {
    char *pem = pp_file_read(path, NULL);
    if (!pem) {
        return NULL;
    }

    char *ret = pp_key_decrypted_from_buffer(pem, passphrase);
    pp_zero(pem, strlen(pem));
    pp_free(pem);
    return ret;
}

char *pp_mbed_key_decrypted_from_pem(const char *pem, const char *passphrase) {
    return pp_key_decrypted_from_buffer(pem, passphrase);
}
