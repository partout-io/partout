//
//  tls.c
//  Partout
//
//  Created by Davide De Rosa on 6/27/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <openssl/err.h>
#include <stdio.h>
#include "crypto/allocation.h"
#include "crypto/tls.h"
#include "macros.h"

//static const char *const TLSBoxClientEKU = "TLS Web Client Authentication";
static const char *const TLSBoxServerEKU = "TLS Web Server Authentication";

static int tls_channel_ex_data_idx = -1;

struct tls_channel_t {
    const tls_channel_options *_Nonnull opt;
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
int tls_channel_verify_peer(int ok, X509_STORE_CTX *_Nonnull ctx) {
    if (!ok) {
        SSL *ssl = X509_STORE_CTX_get_ex_data(ctx, SSL_get_ex_data_X509_STORE_CTX_idx());
        tls_channel_ctx tls = SSL_get_ex_data(ssl, tls_channel_ex_data_idx);
        tls->opt->on_verify_failure();
    }
    return ok;
}

// MARK: -

tls_channel_ctx tls_channel_create(const tls_channel_options *opt, tls_error_code *error) {
    SSL_CTX *ssl_ctx = SSL_CTX_new(TLS_client_method());
    X509 *cert = NULL;
    BIO *cert_bio = NULL;
    EVP_PKEY *pkey = NULL;
    BIO *pkey_bio = NULL;

    SSL_CTX_set_options(ssl_ctx, SSL_OP_NO_SSLv2 | SSL_OP_NO_SSLv3 | SSL_OP_NO_COMPRESSION);
    SSL_CTX_set_verify(ssl_ctx, SSL_VERIFY_PEER, tls_channel_verify_peer);
    SSL_CTX_set_security_level(ssl_ctx, opt->sec_level);

    if (opt->ca_path) {
        if (!SSL_CTX_load_verify_locations(ssl_ctx, opt->ca_path, NULL)) {
            CRYPTO_SET_ERROR(TLSErrorCAUse)
            goto failure;
        }
    }
    if (opt->cert_pem) {
        cert_bio = create_BIO_from_PEM(opt->cert_pem);
        if (!cert_bio) {
            CRYPTO_SET_ERROR(TLSErrorClientCertificateRead)
            goto failure;
        }
        cert = PEM_read_bio_X509(cert_bio, NULL, NULL, NULL);
        if (!cert) {
            CRYPTO_SET_ERROR(TLSErrorClientCertificateRead)
            goto failure;
        }
        if (!SSL_CTX_use_certificate(ssl_ctx, cert)) {
            CRYPTO_SET_ERROR(TLSErrorClientCertificateUse)
            goto failure;
        }
        X509_free(cert);
        BIO_free(cert_bio);

        if (opt->key_pem) {
            pkey_bio = create_BIO_from_PEM(opt->key_pem);
            if (!pkey_bio) {
                CRYPTO_SET_ERROR(TLSErrorClientKeyRead)
                goto failure;
            }
            pkey = PEM_read_bio_PrivateKey(pkey_bio, NULL, NULL, NULL);
            if (!pkey) {
                CRYPTO_SET_ERROR(TLSErrorClientKeyRead)
                goto failure;
            }
            if (!SSL_CTX_use_PrivateKey(ssl_ctx, pkey)) {
                CRYPTO_SET_ERROR(TLSErrorClientKeyUse)
                goto failure;
            }
            EVP_PKEY_free(pkey);
            BIO_free(pkey_bio);
        }
    }

    // no longer fails

    tls_channel_ctx tls = pp_alloc_crypto(sizeof(tls_channel_t));
    tls->opt = opt;
    tls->ssl_ctx = ssl_ctx;
    tls->buf_len = tls->opt->buf_len;
    tls->buf_cipher = pp_alloc_crypto(tls->buf_len);
    tls->buf_plain = pp_alloc_crypto(tls->buf_len);
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

void tls_channel_free(tls_channel_ctx tls) {
    if (!tls) return;

    if (tls->ssl) {
        SSL_free(tls->ssl);
    }
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

    pp_zero(tls->buf_cipher, tls->opt->buf_len);
    pp_zero(tls->buf_plain, tls->opt->buf_len);
    free(tls->buf_cipher);
    free(tls->buf_plain);
    tls_channel_options_free((tls_channel_options *)tls->opt);
    SSL_CTX_free(tls->ssl_ctx);
}

bool tls_channel_start(tls_channel_ctx _Nonnull tls) {
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
    SSL_set_ex_data(tls->ssl, tls_channel_ex_data_idx, tls);

    return SSL_do_handshake(tls->ssl);
}

bool tls_channel_is_connected(tls_channel_ctx _Nonnull tls) {
    return tls->is_connected;
}

// MARK: - I/O

bool tls_channel_verify_ssl_eku(SSL *_Nonnull ssl);
bool tls_channel_verify_ssl_san_host(SSL *_Nonnull ssl, const char *_Nonnull hostname);

zeroing_data_t *_Nullable tls_channel_pull_cipher(tls_channel_ctx _Nonnull tls,
                                                  tls_error_code *_Nullable error) {
    if (error) {
        *error = TLSErrorNone;
    }
    if (!tls->is_connected && !SSL_is_init_finished(tls->ssl)) {
        SSL_do_handshake(tls->ssl);
    }
    const int ret = BIO_read(tls->bio_cipher_out, tls->buf_cipher, (int)tls->opt->buf_len);
    if (!tls->is_connected && SSL_is_init_finished(tls->ssl)) {
        tls->is_connected = true;
        if (tls->opt->eku && !tls_channel_verify_ssl_eku(tls->ssl)) {
            if (error) {
                *error = TLSErrorServerEKU;
            }
            return NULL;
        }
        if (tls->opt->san_host) {
            pp_assert(tls->opt->hostname);
            if (!tls_channel_verify_ssl_san_host(tls->ssl, tls->opt->hostname)) {
                if (error) {
                    *error = TLSErrorServerHost;
                }
                return NULL;
            }
        }
    }
    if ((ret < 0) && !BIO_should_retry(tls->bio_cipher_out)) {
        if (error) {
            *error = TLSErrorHandshake;
        }
        return NULL;
    }
    if (ret <= 0) {
        return NULL;
    }
    return zd_create_from_data(tls->buf_cipher, ret);
}

zeroing_data_t *_Nullable tls_channel_pull_plain(tls_channel_ctx _Nonnull tls,
                                                 tls_error_code *_Nullable error) {
    const int ret = BIO_read(tls->bio_plain, tls->buf_plain, (int)tls->opt->buf_len);
    if (error) {
        *error = TLSErrorNone;
    }
    if ((ret < 0) && !BIO_should_retry(tls->bio_plain)) {
        if (error) {
            *error = TLSErrorHandshake;
        }
        return NULL;
    }
    if (ret <= 0) {
        return NULL;
    }
    return zd_create_from_data(tls->buf_plain, ret);
}

bool tls_channel_put_cipher(tls_channel_ctx _Nonnull tls,
                            const uint8_t *_Nonnull src, size_t src_len,
                            tls_error_code *_Nullable error) {
    if (error) {
        *error = TLSErrorNone;
    }
    const int ret = BIO_write(tls->bio_cipher_in, src, (int)src_len);
    if (ret != (int)src_len) {
        if (error) {
            *error = TLSErrorHandshake;
        }
        return false;
    }
    return true;
}

bool tls_channel_put_plain(tls_channel_ctx _Nonnull tls,
                           const uint8_t *_Nonnull src, size_t src_len,
                           tls_error_code *_Nullable error) {
    if (error) {
        *error = TLSErrorNone;
    }
    const int ret = BIO_write(tls->bio_plain, src, (int)src_len);
    if (ret != (int)src_len) {
        if (error) {
            *error = TLSErrorHandshake;
        }
        return false;
    }
    return true;
}

// MARK: - MD5

char *tls_channel_ca_md5(const tls_channel_ctx tls) {
    const EVP_MD *alg = EVP_get_digestbyname("MD5");
    uint8_t md[16];
    unsigned int len;

    FILE *pem = fopen(tls->opt->ca_path, "r");
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

    char *hex = pp_alloc_crypto(2 * sizeof(md) + 1);
    char *ptr = hex;
    for (size_t i = 0; i < sizeof(md); ++i) {
        ptr += sprintf(ptr, "%02x", md[i]);
    }
    *ptr = '\0';
    return hex;

failure:
    if (pem) fclose(pem);
    return NULL;
}

// MARK: - Verifications

bool tls_channel_verify_ssl_eku(SSL *_Nonnull ssl) {
    X509 *cert = SSL_get1_peer_certificate(ssl);
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

    EXTENDED_KEY_USAGE *eku = X509V3_EXT_d2i(ext);
    if (!eku) {
        goto failure;
    }
    const int num = (int)sk_ASN1_OBJECT_num(eku);
    char buffer[100];
    bool is_valid = false;

    for (int i = 0; i < num; ++i) {
        OBJ_obj2txt(buffer, sizeof(buffer), sk_ASN1_OBJECT_value(eku, i), 1); // get OID
        const char *oid = OBJ_nid2ln(OBJ_obj2nid(sk_ASN1_OBJECT_value(eku, i)));
//        NSLog(@"eku flag %d: %s - %s", i, buffer, oid);
        if (oid && !strcmp(oid, TLSBoxServerEKU)) {
            is_valid = true;
            break;
        }
    }
    EXTENDED_KEY_USAGE_free(eku);
    X509_free(cert);

    return is_valid;

failure:
    if (cert) X509_free(cert);
    return false;
}

bool tls_channel_verify_ssl_san_host(SSL *_Nonnull ssl, const char *_Nonnull hostname) {
    GENERAL_NAMES* names = NULL;
    X509 *cert = NULL;
    unsigned char* utf8 = NULL;

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
        if (!entry) {
            continue;
        }
        if (GEN_DNS != entry->type) {
            continue;
        }

        int len1 = 0, len2 = -1;
        len1 = ASN1_STRING_to_UTF8(&utf8, entry->d.dNSName);
        if (!utf8) {
            continue;
        }
        len2 = (int)strlen((const char *)utf8);

        if (len1 != len2) {
            OPENSSL_free(utf8);
            utf8 = NULL;
            continue;
        }

        if (utf8 && len1 && len2 && (len1 == len2) && strcmp((const char *)utf8, hostname) == 0) {
            OPENSSL_free(utf8);
            utf8 = NULL;
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
