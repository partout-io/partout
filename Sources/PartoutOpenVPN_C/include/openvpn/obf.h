/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdint.h>

// WARNING: assume dst to be able to hold src_len

// TODO: #154, make more efficient by XOR-ing 4-8 bytes per loop

static inline
void openvpn_obf_xor_mask(uint8_t *_Nonnull dst,
                  size_t dst_len,
                  const uint8_t *_Nonnull mask,
                  size_t mask_len) {

    pp_assert(mask && mask_len > 0);
    if (mask_len == 0) {
        return;
    }
    for (size_t i = 0; i < dst_len; ++i) {
        dst[i] ^= mask[i % mask_len];
    }
}

static inline
void openvpn_obf_xor_ptrpos(uint8_t *_Nonnull dst, size_t dst_len) {

    for (size_t i = 0; i < dst_len; ++i) {
        dst[i] ^= ((i + 1) & 0xff);
    }
}

// first byte as-is, [1..n-1] reversed
static inline
void openvpn_obf_reverse(uint8_t *_Nonnull dst, size_t dst_len) {

    if (dst_len <= 2) {
        return;
    }
    size_t start = 1;
    size_t end = dst_len - 1;
    uint8_t temp = 0;
    while (start < end) {
        temp = dst[start];
        dst[start] = dst[end];
        dst[end] = temp;
        start++;
        end--;
    }
}

static inline
void openvpn_obf_xor_obfuscate(uint8_t *_Nonnull dst,
                       size_t dst_len,
                       const uint8_t *_Nonnull mask,
                       size_t mask_len,
                       bool outbound)
{
    if (outbound) {
        openvpn_obf_xor_ptrpos(dst, dst_len);
        openvpn_obf_reverse(dst, dst_len);
        openvpn_obf_xor_ptrpos(dst, dst_len);
        openvpn_obf_xor_mask(dst, dst_len, mask, mask_len);
    } else {
        openvpn_obf_xor_mask(dst, dst_len, mask, mask_len);
        openvpn_obf_xor_ptrpos(dst, dst_len);
        openvpn_obf_reverse(dst, dst_len);
        openvpn_obf_xor_ptrpos(dst, dst_len);
    }
}
