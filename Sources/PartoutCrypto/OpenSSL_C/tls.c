/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <openssl/err.h>
#include <stdio.h>
#include "portable/common.h"
#include "tls/tls.h"
#include "tls/macros.h"

//static const char *const TLSBoxClientEKU = "TLS Web Client Authentication";
static const char *const TLSBoxServerEKU = "TLS Web Server Authentication";

static int PPTLSExDataIdx = -1;

struct _pp_tls {
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
    if (!ok) {
        pp_clog_v(PPLogCategoryCore, PPLogLevelError,
                  "pp_tls_verify_peer: error %d", X509_STORE_CTX_get_error(ctx));
        SSL *ssl = X509_STORE_CTX_get_ex_data(ctx, SSL_get_ex_data_X509_STORE_CTX_idx());
        pp_tls tls = SSL_get_ex_data(ssl, PPTLSExDataIdx);
        assert(tls);
        if (tls) {
            tls->opt->on_verify_failure();
        }
    }
    return ok;
}

// MARK: -

pp_tls pp_tls_create(const pp_tls_options *opt, pp_tls_error_code *error) {
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

void pp_tls_free(pp_tls tls) {
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

bool pp_tls_start(pp_tls _Nonnull tls) {
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

bool pp_tls_is_connected(pp_tls _Nonnull tls) {
    return tls->is_connected;
}

// MARK: - I/O

bool pp_tls_verify_ssl_eku(SSL *_Nonnull ssl);
bool pp_tls_verify_ssl_san_host(SSL *_Nonnull ssl, const char *_Nonnull hostname);

pp_zd *_Nullable pp_tls_pull_cipher(pp_tls _Nonnull tls,
                                                  pp_tls_error_code *_Nullable error) {
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

pp_zd *_Nullable pp_tls_pull_plain(pp_tls _Nonnull tls,
                                                 pp_tls_error_code *_Nullable error) {
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

bool pp_tls_put_cipher(pp_tls _Nonnull tls,
                            const uint8_t *_Nonnull src, size_t src_len,
                            pp_tls_error_code *_Nullable error) {
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

bool pp_tls_put_plain(pp_tls _Nonnull tls,
                           const uint8_t *_Nonnull src, size_t src_len,
                           pp_tls_error_code *_Nullable error) {
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

char *pp_tls_ca_md5(const pp_tls tls) {
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

bool pp_tls_verify_ssl_eku(SSL *_Nonnull ssl) {
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

bool pp_tls_verify_ssl_san_host(SSL *_Nonnull ssl, const char *_Nonnull hostname) {
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
