//
//  xor.h
//  Partout
//
//  Created by Tejas Mehta on 5/24/22.
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

#pragma once

#include <stdint.h>
#include <string.h>

typedef enum {
    XORMethodNone,
    XORMethodMask,
    XORMethodPtrPos,
    XORMethodReverse,
    XORMethodObfuscate
} xor_method_t;

// WARNING: assume dst to be able to hold src_len

// TODO: ##, make more efficient by XOR-ing 4-8 bytes per loop

static inline
void xor_mask_copy(uint8_t *_Nonnull dst,
                   const uint8_t *_Nonnull src,
                   size_t src_len,
                   const uint8_t *_Nonnull mask,
                   size_t mask_len) {

    assert(mask && mask_len > 0);
    if (mask_len == 0) {
        return;
    }
    for (size_t i = 0; i < src_len; ++i) {
        dst[i] = src[i] ^ mask[i % mask_len];
    }
}

static inline
void xor_ptrpos_copy(uint8_t *_Nonnull dst,
                     const uint8_t *_Nonnull src,
                     size_t src_len) {

    for (size_t i = 0; i < src_len; ++i) {
        dst[i] = src[i] ^ ((i + 1) & 0xff);
    }
}

// FIXME: ##, this does not XOR, change functions xor_ prefix to something else
// first byte as-is, [1..n-1] reversed
static inline
void xor_reverse_copy(uint8_t *_Nonnull dst,
                      const uint8_t *_Nonnull src,
                      size_t src_len) {

    if (src_len <= 2) {
        return;
    }
    size_t start = 1;
    size_t end = src_len - 1;
    uint8_t temp = 0;
    dst[0] = src[0];
    while (start < end) {
        temp = src[start];
        dst[start] = src[end];
        dst[end] = temp;
        start++;
        end--;
    }
    if (start == end) {
        dst[start] = src[start];
    }
}

static inline
void xor_obfuscate_copy(uint8_t *_Nonnull dst,
                        const uint8_t *_Nonnull src,
                        size_t src_len,
                        const uint8_t *_Nonnull mask,
                        size_t mask_len,
                        bool outbound)
{
    if (outbound) {
        xor_ptrpos_copy(dst, src, src_len);
        xor_reverse_copy(dst, dst, src_len);
        xor_ptrpos_copy(dst, dst, src_len);
        xor_mask_copy(dst, dst, src_len, mask, mask_len);
    } else {
        xor_mask_copy(dst, src, src_len, mask, mask_len);
        xor_ptrpos_copy(dst, dst, src_len);
        xor_reverse_copy(dst, dst, src_len);
        xor_ptrpos_copy(dst, dst, src_len);
    }
}

// MARK: - In-place

static inline
void xor_mask(uint8_t *_Nonnull dst,
              size_t dst_len,
              const uint8_t *_Nonnull mask,
              size_t mask_len) {

    xor_mask_copy(dst, dst, dst_len, mask, mask_len);
}

static inline
void xor_ptrpos(uint8_t *_Nonnull dst, size_t dst_len) {
    xor_ptrpos_copy(dst, dst, dst_len);
}

static inline
void xor_reverse(uint8_t *_Nonnull dst, size_t dst_len) {
    xor_reverse_copy(dst, dst, dst_len);
}

static inline
void xor_obfuscate(uint8_t *_Nonnull dst,
                   size_t dst_len,
                   const uint8_t *_Nonnull mask,
                   size_t mask_len,
                   bool outbound) {

    xor_obfuscate_copy(dst, dst, dst_len, mask, mask_len, outbound);
}

// MARK: - Generic

static inline
void xor_memcpy(uint8_t *_Nonnull dst,
                const uint8_t *_Nonnull src,
                size_t src_len,
                xor_method_t method,
                const uint8_t *_Nonnull mask,
                size_t mask_len,
                bool outbound) {

    switch (method) {
        case XORMethodNone:
            memcpy(dst, src, src_len);
            break;
        case XORMethodMask:
            xor_mask_copy(dst, src, src_len, mask, mask_len);
            break;
        case XORMethodPtrPos:
            xor_ptrpos_copy(dst, src, src_len);
            break;
        case XORMethodReverse:
            xor_reverse_copy(dst, src, src_len);
            break;
        case XORMethodObfuscate:
            xor_obfuscate_copy(dst, src, src_len, mask, mask_len, outbound);
            break;
    }
}
