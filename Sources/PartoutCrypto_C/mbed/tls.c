/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <limits.h>
#include <mbedtls/asn1.h>
#include <mbedtls/error.h>
#include <mbedtls/oid.h>
#include <mbedtls/pk.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <psa/crypto.h>
#include "portable/common.h"
#include "crypto/tls.h"

typedef struct {
    uint8_t *_Nullable bytes;
    size_t length;
    size_t capacity;
} pp_tls_buffer;

struct __pp_tls_struct {
    const pp_tls_options *_Nonnull opt;

    mbedtls_ssl_config conf;
    mbedtls_ssl_context ssl;
    mbedtls_x509_crt ca;
    mbedtls_x509_crt cert;
    mbedtls_pk_context key;
    mbedtls_x509_crt_profile profile;

    size_t buf_len;
    uint8_t *_Nonnull buf_cipher;
    uint8_t *_Nonnull buf_plain;
    pp_tls_buffer cipher_in;
    pp_tls_buffer cipher_out;
    pp_tls_buffer plain_out;

    bool did_setup;
    bool did_fail_verify;
    bool is_connected;
};

static
void pp_tls_set_error(pp_tls_error_code *_Nullable error,
                      pp_tls_error_code code) {
    if (error) {
        *error = code;
    }
}

static
void pp_tls_log_mbed_error(const char *op, int ret) {
    char msg[128];
    mbedtls_strerror(ret, msg, sizeof(msg));
    pp_clog_v(PPLogCategoryCore, PPLogLevelError,
              "%s: mbedTLS error -0x%04x (%s)", op, ret < 0 ? -ret : ret, msg);
}

static
bool pp_tls_init_psa(void) {
    return psa_crypto_init() == PSA_SUCCESS;
}

static
void pp_tls_buffer_free(pp_tls_buffer *buf) {
    if (!buf || !buf->bytes) return;

    pp_zero(buf->bytes, buf->capacity);
    pp_free(buf->bytes);
    buf->bytes = NULL;
    buf->length = 0;
    buf->capacity = 0;
}

static
void pp_tls_buffer_clear(pp_tls_buffer *buf) {
    if (!buf || !buf->bytes) return;

    pp_zero(buf->bytes, buf->capacity);
    buf->length = 0;
}

static
void pp_tls_buffer_reserve(pp_tls_buffer *buf, size_t capacity) {
    if (capacity <= buf->capacity) return;

    size_t new_capacity = buf->capacity ? buf->capacity : 1024;
    while (new_capacity < capacity) {
        if (new_capacity > (SIZE_MAX / 2)) {
            pp_clog(PPLogCategoryCore, PPLogLevelFault,
                    "pp_tls_buffer_reserve: capacity overflow");
            abort();
        }
        new_capacity *= 2;
    }

    uint8_t *new_bytes = pp_alloc(new_capacity);
    if (buf->bytes) {
        memcpy(new_bytes, buf->bytes, buf->length);
        pp_zero(buf->bytes, buf->capacity);
        pp_free(buf->bytes);
    }
    buf->bytes = new_bytes;
    buf->capacity = new_capacity;
}

static
void pp_tls_buffer_append(pp_tls_buffer *buf,
                          const uint8_t *src, size_t src_len) {
    if (!src_len) return;
    if (buf->length > SIZE_MAX - src_len) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault,
                "pp_tls_buffer_append: length overflow");
        abort();
    }

    pp_tls_buffer_reserve(buf, buf->length + src_len);
    memcpy(buf->bytes + buf->length, src, src_len);
    buf->length += src_len;
}

static
size_t pp_tls_buffer_pop(pp_tls_buffer *buf, uint8_t *dst, size_t dst_len) {
    const size_t len = (buf->length < dst_len) ? buf->length : dst_len;
    if (!len) return 0;

    memcpy(dst, buf->bytes, len);
    if (len < buf->length) {
        memmove(buf->bytes, buf->bytes + len, buf->length - len);
        pp_zero(buf->bytes + buf->length - len, len);
    } else {
        pp_zero(buf->bytes, buf->length);
    }
    buf->length -= len;
    return len;
}

static
pp_zd *_Nullable pp_tls_buffer_drain_zd(pp_tls_buffer *buf) {
    if (!buf->length) {
        return NULL;
    }

    pp_zd *zd = pp_zd_create_from_data(buf->bytes, buf->length);
    pp_tls_buffer_clear(buf);
    return zd;
}

static
int pp_tls_send(void *ctx, const unsigned char *buf, size_t len) {
    pp_tls tls = ctx;
    const size_t capped_len = (len > (size_t)INT_MAX) ? (size_t)INT_MAX : len;
    pp_tls_buffer_append(&tls->cipher_out, buf, capped_len);
    return (int)capped_len;
}

static
int pp_tls_recv(void *ctx, unsigned char *buf, size_t len) {
    pp_tls tls = ctx;
    if (!tls->cipher_in.length) {
        return MBEDTLS_ERR_SSL_WANT_READ;
    }
    const size_t capped_len = (len > (size_t)INT_MAX) ? (size_t)INT_MAX : len;
    return (int)pp_tls_buffer_pop(&tls->cipher_in, buf, capped_len);
}

static
bool pp_tls_is_retry(int ret) {
    return ret == MBEDTLS_ERR_SSL_WANT_READ ||
           ret == MBEDTLS_ERR_SSL_WANT_WRITE ||
           ret == MBEDTLS_ERR_SSL_ASYNC_IN_PROGRESS ||
           ret == MBEDTLS_ERR_SSL_CRYPTO_IN_PROGRESS;
}

static
bool pp_tls_is_no_data(int ret) {
    return pp_tls_is_retry(ret) ||
           ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY ||
           ret == MBEDTLS_ERR_SSL_CONN_EOF;
}

static
bool pp_tls_pump_plain(pp_tls tls, pp_tls_error_code *_Nullable error) {
    while (true) {
        const int ret = mbedtls_ssl_read(&tls->ssl, tls->buf_plain, tls->buf_len);
        if (ret > 0) {
            pp_tls_buffer_append(&tls->plain_out, tls->buf_plain, (size_t)ret);
            continue;
        }
        if (ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) {
            continue;
        }
        if (ret == 0 || pp_tls_is_no_data(ret)) {
            return true;
        }

        pp_tls_log_mbed_error("mbedtls_ssl_read", ret);
        pp_tls_set_error(error, PPTLSErrorHandshake);
        return false;
    }
}

static
void pp_tls_configure_profile(pp_tls tls) {
    if (tls->opt->sec_level <= 0) {
        tls->profile.allowed_mds = UINT32_MAX;
        tls->profile.allowed_pks = UINT32_MAX;
        tls->profile.allowed_curves = UINT32_MAX;
        tls->profile.rsa_min_bitlen = 0;
    } else if (tls->opt->sec_level == 1) {
        tls->profile.allowed_mds = UINT32_MAX & ~MBEDTLS_X509_ID_FLAG(MBEDTLS_MD_MD5);
        tls->profile.allowed_pks = UINT32_MAX;
        tls->profile.allowed_curves = UINT32_MAX;
        tls->profile.rsa_min_bitlen = 1024;
    } else {
        tls->profile = mbedtls_x509_crt_profile_default;
        switch (tls->opt->sec_level) {
        case 2:
            tls->profile.rsa_min_bitlen = 2048;
            break;
        case 3:
            tls->profile.rsa_min_bitlen = 3072;
            break;
        case 4:
            tls->profile.rsa_min_bitlen = 7680;
            break;
        default:
            tls->profile.rsa_min_bitlen = 15360;
            break;
        }
    }
}

static
int pp_tls_verify_peer(void *ctx, mbedtls_x509_crt *crt, int depth, uint32_t *flags) {
    (void)crt;
    (void)depth;

    if (flags && *flags) {
        pp_tls tls = ctx;
        tls->did_fail_verify = true;
        pp_clog_v(PPLogCategoryCore, PPLogLevelError,
                  "pp_tls_verify_peer: flags 0x%08x", (unsigned int)*flags);
        tls->opt->on_verify_failure(tls->opt->ctx);
    }
    return 0;
}

static
bool pp_tls_verify_mbed_eku(const mbedtls_ssl_context *ssl) {
    const mbedtls_x509_crt *cert = mbedtls_ssl_get_peer_cert(ssl);
    if (!cert) {
        return false;
    }
    if (!mbedtls_x509_crt_has_ext_type(cert, MBEDTLS_X509_EXT_EXTENDED_KEY_USAGE)) {
        return false;
    }

    for (const mbedtls_x509_sequence *cur = &cert->ext_key_usage;
         cur != NULL;
         cur = cur->next) {
        if (cur->buf.len == MBEDTLS_OID_SIZE(MBEDTLS_OID_SERVER_AUTH) &&
            memcmp(cur->buf.p, MBEDTLS_OID_SERVER_AUTH, cur->buf.len) == 0) {
            return true;
        }
    }
    return false;
}

static
bool pp_tls_verify_mbed_san_host(const mbedtls_ssl_context *ssl, const char *hostname) {
    const mbedtls_x509_crt *cert = mbedtls_ssl_get_peer_cert(ssl);
    if (!cert) {
        return false;
    }
    if (!mbedtls_x509_crt_has_ext_type(cert, MBEDTLS_X509_EXT_SUBJECT_ALT_NAME)) {
        return false;
    }

    const size_t hostname_len = strlen(hostname);
    for (const mbedtls_x509_sequence *cur = &cert->subject_alt_names;
         cur != NULL;
         cur = cur->next) {
        if (((unsigned char)cur->buf.tag & MBEDTLS_ASN1_TAG_VALUE_MASK) !=
            MBEDTLS_X509_SAN_DNS_NAME) {
            continue;
        }
        if (cur->buf.len == hostname_len &&
            memcmp(cur->buf.p, hostname, hostname_len) == 0) {
            return true;
        }
    }
    return false;
}

static
void pp_tls_free_internal(pp_tls tls, bool free_options) {
    if (!tls) return;

    mbedtls_ssl_free(&tls->ssl);
    mbedtls_ssl_config_free(&tls->conf);
    mbedtls_x509_crt_free(&tls->ca);
    mbedtls_x509_crt_free(&tls->cert);
    mbedtls_pk_free(&tls->key);

    if (tls->buf_cipher) {
        pp_zero(tls->buf_cipher, tls->buf_len);
        pp_free(tls->buf_cipher);
    }
    if (tls->buf_plain) {
        pp_zero(tls->buf_plain, tls->buf_len);
        pp_free(tls->buf_plain);
    }
    pp_tls_buffer_free(&tls->cipher_in);
    pp_tls_buffer_free(&tls->cipher_out);
    pp_tls_buffer_free(&tls->plain_out);

    if (free_options) {
        pp_tls_options_free((pp_tls_options *)tls->opt);
    }
    pp_free(tls);
}

pp_tls pp_mbed_tls_create(const pp_tls_options *opt, pp_tls_error_code *error) {
    pp_tls_set_error(error, PPTLSErrorNone);
    if (!pp_tls_init_psa()) {
        pp_tls_set_error(error, PPTLSErrorHandshake);
        return NULL;
    }

    pp_tls tls = pp_alloc(sizeof(*tls));
    tls->opt = opt;
    tls->buf_len = opt->buf_len;
    tls->buf_cipher = pp_alloc(tls->buf_len);
    tls->buf_plain = pp_alloc(tls->buf_len);

    mbedtls_ssl_config_init(&tls->conf);
    mbedtls_ssl_init(&tls->ssl);
    mbedtls_x509_crt_init(&tls->ca);
    mbedtls_x509_crt_init(&tls->cert);
    mbedtls_pk_init(&tls->key);

    int ret = mbedtls_x509_crt_parse_file(&tls->ca, opt->ca_path);
    if (ret != 0) {
        pp_tls_log_mbed_error("mbedtls_x509_crt_parse_file", ret);
        pp_tls_set_error(error, PPTLSErrorCAUse);
        goto failure;
    }

    ret = mbedtls_ssl_config_defaults(&tls->conf,
                                      MBEDTLS_SSL_IS_CLIENT,
                                      MBEDTLS_SSL_TRANSPORT_STREAM,
                                      MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) {
        pp_tls_log_mbed_error("mbedtls_ssl_config_defaults", ret);
        pp_tls_set_error(error, PPTLSErrorHandshake);
        goto failure;
    }

    pp_tls_configure_profile(tls);
    mbedtls_ssl_conf_cert_profile(&tls->conf, &tls->profile);
    mbedtls_ssl_conf_ca_chain(&tls->conf, &tls->ca, NULL);
    mbedtls_ssl_conf_authmode(&tls->conf, MBEDTLS_SSL_VERIFY_OPTIONAL);
#if defined(MBEDTLS_SSL_SESSION_TICKETS) && defined(MBEDTLS_SSL_CLI_C)
    mbedtls_ssl_conf_session_tickets(&tls->conf,
                                     MBEDTLS_SSL_SESSION_TICKETS_DISABLED);
#endif

    if (opt->cert_pem) {
        ret = mbedtls_x509_crt_parse(&tls->cert,
                                     (const unsigned char *)opt->cert_pem,
                                     strlen(opt->cert_pem) + 1);
        if (ret != 0) {
            pp_tls_log_mbed_error("mbedtls_x509_crt_parse", ret);
            pp_tls_set_error(error, PPTLSErrorClientCertificateRead);
            goto failure;
        }

        if (opt->key_pem) {
            ret = mbedtls_pk_parse_key(&tls->key,
                                       (const unsigned char *)opt->key_pem,
                                       strlen(opt->key_pem) + 1,
                                       NULL,
                                       0);
            if (ret != 0) {
                pp_tls_log_mbed_error("mbedtls_pk_parse_key", ret);
                pp_tls_set_error(error, PPTLSErrorClientKeyRead);
                goto failure;
            }
            ret = mbedtls_ssl_conf_own_cert(&tls->conf, &tls->cert, &tls->key);
            if (ret != 0) {
                pp_tls_log_mbed_error("mbedtls_ssl_conf_own_cert", ret);
                pp_tls_set_error(error, PPTLSErrorClientKeyUse);
                goto failure;
            }
        }
    }

    return tls;

failure:
    pp_tls_free_internal(tls, false);
    return NULL;
}

void pp_mbed_tls_free(pp_tls tls) {
    pp_tls_free_internal(tls, true);
}

bool pp_mbed_tls_start(pp_tls tls) {
    if (tls->did_setup) {
        mbedtls_ssl_free(&tls->ssl);
        mbedtls_ssl_init(&tls->ssl);
        tls->did_setup = false;
    }

    pp_zero(tls->buf_cipher, tls->buf_len);
    pp_zero(tls->buf_plain, tls->buf_len);
    pp_tls_buffer_clear(&tls->cipher_in);
    pp_tls_buffer_clear(&tls->cipher_out);
    pp_tls_buffer_clear(&tls->plain_out);
    tls->did_fail_verify = false;
    tls->is_connected = false;

    int ret = mbedtls_ssl_setup(&tls->ssl, &tls->conf);
    if (ret != 0) {
        pp_tls_log_mbed_error("mbedtls_ssl_setup", ret);
        return false;
    }
    tls->did_setup = true;
    mbedtls_ssl_set_bio(&tls->ssl, tls, pp_tls_send, pp_tls_recv, NULL);
    mbedtls_ssl_set_verify(&tls->ssl, pp_tls_verify_peer, tls);

    ret = mbedtls_ssl_handshake(&tls->ssl);
    if (ret != 0 && !pp_tls_is_retry(ret)) {
        pp_tls_log_mbed_error("mbedtls_ssl_handshake", ret);
        return false;
    }
    return true;
}

bool pp_mbed_tls_is_connected(pp_tls tls) {
    return tls->is_connected;
}

// MARK: - I/O

pp_zd *_Nullable pp_mbed_tls_pull_cipher(pp_tls tls, pp_tls_error_code *_Nullable error) {
    pp_tls_set_error(error, PPTLSErrorNone);

    int ret = 0;
    if (!tls->is_connected && !mbedtls_ssl_is_handshake_over(&tls->ssl)) {
        ret = mbedtls_ssl_handshake(&tls->ssl);
    }

    if (!tls->is_connected && mbedtls_ssl_is_handshake_over(&tls->ssl)) {
        const uint32_t verify_result = mbedtls_ssl_get_verify_result(&tls->ssl);
        if (verify_result != 0) {
            if (!tls->did_fail_verify) {
                tls->opt->on_verify_failure(tls->opt->ctx);
                tls->did_fail_verify = true;
            }
            pp_tls_set_error(error, PPTLSErrorHandshake);
            return NULL;
        }

        tls->is_connected = true;
        if (tls->opt->eku && !pp_tls_verify_mbed_eku(&tls->ssl)) {
            pp_tls_set_error(error, PPTLSErrorServerEKU);
            return NULL;
        }
        if (tls->opt->san_host) {
            pp_assert(tls->opt->hostname);
            if (!pp_tls_verify_mbed_san_host(&tls->ssl, tls->opt->hostname)) {
                pp_tls_set_error(error, PPTLSErrorServerHost);
                return NULL;
            }
        }
    }

    pp_tls_error_code plain_error = PPTLSErrorNone;
    const bool did_fail_plain = tls->is_connected &&
                                !pp_tls_pump_plain(tls, &plain_error);
    pp_zd *cipher = pp_tls_buffer_drain_zd(&tls->cipher_out);

    if (ret != 0 && !pp_tls_is_retry(ret)) {
        if (!cipher) {
            pp_tls_log_mbed_error("mbedtls_ssl_handshake", ret);
            pp_tls_set_error(error, PPTLSErrorHandshake);
            return NULL;
        }
    }
    if (did_fail_plain) {
        if (!cipher) {
            pp_tls_set_error(error, plain_error);
            return NULL;
        }
    }
    if (!cipher) {
        return NULL;
    }
    return cipher;
}

pp_zd *_Nullable pp_mbed_tls_pull_plain(pp_tls tls, pp_tls_error_code *_Nullable error) {
    pp_tls_set_error(error, PPTLSErrorNone);

    pp_zd *plain = pp_tls_buffer_drain_zd(&tls->plain_out);
    if (plain) {
        return plain;
    }

    while (true) {
        const int ret = mbedtls_ssl_read(&tls->ssl, tls->buf_plain, tls->buf_len);
        if (ret > 0) {
            return pp_zd_create_from_data(tls->buf_plain, (size_t)ret);
        }
        if (ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) {
            continue;
        }
        if (ret == 0 || pp_tls_is_no_data(ret)) {
            return NULL;
        }

        pp_tls_log_mbed_error("mbedtls_ssl_read", ret);
        pp_tls_set_error(error, PPTLSErrorHandshake);
        return NULL;
    }
}

bool pp_mbed_tls_put_cipher(pp_tls tls,
                            const uint8_t *src, size_t src_len,
                            pp_tls_error_code *_Nullable error) {
    pp_tls_set_error(error, PPTLSErrorNone);
    pp_tls_buffer_append(&tls->cipher_in, src, src_len);
    return true;
}

bool pp_mbed_tls_put_plain(pp_tls tls,
                           const uint8_t *src, size_t src_len,
                           pp_tls_error_code *_Nullable error) {
    pp_tls_set_error(error, PPTLSErrorNone);

    size_t offset = 0;
    while (offset < src_len) {
        size_t chunk_len = src_len - offset;
        if (chunk_len > (size_t)INT_MAX) {
            chunk_len = (size_t)INT_MAX;
        }

        const int ret = mbedtls_ssl_write(&tls->ssl, src + offset, chunk_len);
        if (ret <= 0) {
            pp_tls_log_mbed_error("mbedtls_ssl_write", ret);
            pp_tls_set_error(error, PPTLSErrorHandshake);
            return false;
        }
        offset += (size_t)ret;
    }
    return true;
}

// MARK: - MD5

char *pp_mbed_tls_ca_md5(const pp_tls tls) {
    if (!pp_tls_init_psa()) {
        return NULL;
    }

    mbedtls_x509_crt cert;
    mbedtls_x509_crt_init(&cert);

    uint8_t md[16];
    size_t len = 0;
    char *hex = NULL;

    int ret = mbedtls_x509_crt_parse_file(&cert, tls->opt->ca_path);
    if (ret != 0) {
        pp_tls_log_mbed_error("mbedtls_x509_crt_parse_file", ret);
        goto failure;
    }
    if (psa_hash_compute(PSA_ALG_MD5,
                         cert.raw.p,
                         cert.raw.len,
                         md,
                         sizeof(md),
                         &len) != PSA_SUCCESS) {
        goto failure;
    }
    pp_assert(len == sizeof(md));

    hex = pp_alloc(2 * sizeof(md) + 1);
    char *ptr = hex;
    for (size_t i = 0; i < sizeof(md); ++i) {
        ptr += snprintf(ptr, 3, "%02x", md[i]);
    }
    *ptr = '\0';

failure:
    mbedtls_x509_crt_free(&cert);
    return hex;
}
