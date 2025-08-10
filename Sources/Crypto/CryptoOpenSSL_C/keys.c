/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include "crypto/allocation.h"
#include "crypto/keys.h"

#define KeyHMACMaxLength    (size_t)128

bool key_init_seed(const pp_zd *seed) {
    unsigned char x[1];
    if (RAND_bytes(x, 1) != 1) {
        return false;
    }
    RAND_seed(seed->bytes, (int)seed->length);
    return true;
}

pp_zd *key_hmac_create() {
    return zd_create(KeyHMACMaxLength);
}

size_t key_hmac_do(key_hmac_ctx *ctx) {
    pp_assert(ctx->dst->length >= KeyHMACMaxLength);

    const EVP_MD *md = EVP_get_digestbyname(ctx->digest_name);
    if (!md) {
        return 0;
    }
    unsigned int dst_len = 0;
    const bool success = HMAC(md,
                              ctx->secret->bytes,
                              (int)ctx->secret->length,
                              ctx->data->bytes,
                              ctx->data->length,
                              ctx->dst->bytes,
                              &dst_len) != NULL;
    if (!success) {
        return 0;
    }
    return dst_len;
}

// MARK: -

static
char *key_decrypted_from_pkey(const EVP_PKEY *_Nonnull key) {
    BIO *output = BIO_new(BIO_s_mem());
    if (!PEM_write_bio_PrivateKey(output, key, NULL, NULL, 0, NULL, NULL)) {
        BIO_free(output);
        return NULL;
    }

    size_t dec_len = BIO_ctrl_pending(output);
    char *dec_bytes = pp_alloc_crypto(dec_len + 1);
    if (BIO_read(output, dec_bytes, (int)dec_len) < 0) {
        BIO_free(output);
        return NULL;
    }
    BIO_free(output);

    dec_bytes[dec_len] = '\0';
    return dec_bytes;
}

static
char *key_decrypted_from_bio(BIO *_Nonnull bio, const char *_Nonnull passphrase) {
    EVP_PKEY *key;
    if (!(key = PEM_read_bio_PrivateKey(bio, NULL, NULL, (void *)passphrase))) {
        return NULL;
    }
    char *ret = key_decrypted_from_pkey(key);
    EVP_PKEY_free(key);
    return ret;
}

char *key_decrypted_from_path(const char *path, const char *passphrase) {
    BIO *bio;
    if (!(bio = BIO_new_file(path, "r"))) {
        return NULL;
    }
    char *ret = key_decrypted_from_bio(bio, passphrase);
    BIO_free(bio);
    return ret;
}

char *key_decrypted_from_pem(const char *pem, const char *passphrase) {
    BIO *bio;
    if (!(bio = BIO_new_mem_buf(pem, (int)strlen(pem)))) {
        return NULL;
    }
    char *ret = key_decrypted_from_bio(bio, passphrase);
    BIO_free(bio);
    return ret;
}
