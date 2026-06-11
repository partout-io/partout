/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/common.h"
#include "openvpn/dp_macros.h"
#include "openvpn/test/crypto_mock.h"

static inline
void reverse(uint8_t *dst, const uint8_t *src, size_t len) {
    for (size_t i = 0; i < len; i++) {
        dst[i] = src[len - 1 - i];
    }
}

size_t mock_capacity(const void *vctx, size_t len) {
    (void)vctx;
    return 10 * len; // be ridiculously safe
}

// in -> aabb(reversed)ccdd
static
size_t mock_encrypt(void *vctx,
                    uint8_t *out, size_t out_buf_len,
                    const uint8_t *in, size_t in_len,
                    const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    (void)vctx;
    (void)out_buf_len;
    (void)flags;
    (void)error;
    OPENVPN_DP_LOG("openvpn_crypto_mock_encrypt");
    out[0] = 0xaa;
    out[1] = 0xbb;
    reverse(out + 2, in, in_len);
    out[2 + in_len] = 0xcc;
    out[2 + in_len + 1] = 0xdd;
    const size_t out_len = in_len + 4;
    return out_len;
}

// in -> reversed
static
size_t mock_decrypt(void *vctx,
                    uint8_t *out, size_t out_buf_len,
                    const uint8_t *in, size_t in_len,
                    const pp_crypto_flags *flags, pp_crypto_error_code *error) {
    (void)vctx;
    (void)out_buf_len;
    (void)flags;
    (void)error;
    OPENVPN_DP_LOG("openvpn_crypto_mock_decrypt");
    size_t out_len = in_len - 4;
    pp_assert(in[0] == 0xaa);
    pp_assert(in[1] == 0xbb);
    reverse(out, in + 2, out_len);
    pp_assert(in[2 + out_len] == 0xcc);
    pp_assert(in[2 + out_len + 1] == 0xdd);
    return out_len;
}

static
bool mock_verify(void *vctx, const uint8_t *in, size_t in_len, pp_crypto_error_code *error) {
    (void)vctx;
    (void)in;
    (void)in_len;
    (void)error;
    OPENVPN_DP_LOG("openvpn_crypto_mock_verify");
    return true;
}

// MARK: -

pp_crypto_ctx openvpn_crypto_mock_create() {
    OPENVPN_DP_LOG("openvpn_crypto_mock_create");
    openvpn_crypto_mock *ctx = pp_alloc(sizeof(openvpn_crypto_mock));
    ctx->crypto.encrypter.encrypt = mock_encrypt;
    ctx->crypto.decrypter.decrypt = mock_decrypt;
    ctx->crypto.decrypter.verify = mock_verify;
    ctx->crypto.meta.cipher_iv_len = 0;
    ctx->crypto.meta.digest_len = 0;
    ctx->crypto.meta.tag_len = 0;
    ctx->crypto.meta.encryption_capacity = mock_capacity;
    return (pp_crypto_ctx)ctx;
}

void openvpn_crypto_mock_free(pp_crypto_ctx vctx) {
    if (!vctx) return;
    openvpn_crypto_mock *ctx = (openvpn_crypto_mock *)vctx;
    OPENVPN_DP_LOG("openvpn_crypto_mock_free");
    pp_free(ctx);
}
