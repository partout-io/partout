/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

#import "XORMethodNative.h"

static inline
void xor_mask_legacy(uint8_t *dst,
                     const uint8_t *src,
                     size_t srcLength,
                     ZeroingData *xorMask)
{
    assert(xorMask);
    if (!xorMask || xorMask.length == 0) {
        return;
    }
    for (size_t i = 0; i < srcLength; ++i) {
        dst[i] = src[i] ^ ((uint8_t *)(xorMask.bytes))[i % xorMask.length];
    }
}

static inline
void xor_ptrpos_legacy(uint8_t *dst, const uint8_t *src, size_t srcLength)
{
    for (size_t i = 0; i < srcLength; ++i) {
        dst[i] = src[i] ^ ((i + 1) & 0xff);
    }
}

static inline
void xor_reverse_legacy(uint8_t *dst, const uint8_t *src, size_t srcLength)
{
    size_t start = 1;
    size_t end = srcLength - 1;
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
void xor_obfuscate_legacy(uint8_t *dst, const uint8_t *src, size_t srcLength, ZeroingData *mask, BOOL outbound)
{
    if (outbound) {
        xor_ptrpos_legacy(dst, src, srcLength);
        xor_reverse_legacy(dst, dst, srcLength);
        xor_ptrpos_legacy(dst, dst, srcLength);
        xor_mask_legacy(dst, dst, srcLength, mask);
    } else {
        xor_mask_legacy(dst, src, srcLength, mask);
        xor_ptrpos_legacy(dst, dst, srcLength);
        xor_reverse_legacy(dst, dst, srcLength);
        xor_ptrpos_legacy(dst, dst, srcLength);
    }
}

static inline
void xor_memcpy_legacy(uint8_t *dst, NSData *srcData, XORMethodNative method, ZeroingData *mask, BOOL outbound)
{
    const uint8_t *src = srcData.bytes;
    switch (method) {
        case XORMethodNativeNone:
            memcpy(dst, src, srcData.length);
            break;

        case XORMethodNativeMask:
            xor_mask_legacy(dst, src, srcData.length, mask);
            break;

        case XORMethodNativePtrPos:
            xor_ptrpos_legacy(dst, src, srcData.length);
            break;

        case XORMethodNativeReverse:
            xor_reverse_legacy(dst, src, srcData.length);
            break;

        case XORMethodNativeObfuscate:
            xor_obfuscate_legacy(dst, src, srcData.length, mask, outbound);
            break;
    }
}
