/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include "portable/common.h"
#include "crypto/hmac.h"
#include "crypto/keys.h"

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

char *pp_key_decrypted_from_path(const char *path, const char *passphrase) {
    BIO *bio;
    if (!(bio = BIO_new_file(path, "r"))) {
        return NULL;
    }
    char *ret = pp_key_decrypted_from_bio(bio, passphrase);
    BIO_free(bio);
    return ret;
}

char *pp_key_decrypted_from_pem(const char *pem, const char *passphrase) {
    BIO *bio;
    if (!(bio = BIO_new_mem_buf(pem, (int)strlen(pem)))) {
        return NULL;
    }
    char *ret = pp_key_decrypted_from_bio(bio, passphrase);
    BIO_free(bio);
    return ret;
}
