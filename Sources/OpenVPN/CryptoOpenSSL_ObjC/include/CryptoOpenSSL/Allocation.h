/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#import <Foundation/Foundation.h>

static inline
void *_Nonnull pp_alloc_crypto(size_t size) {
    void *memory = calloc(1, size);
    if (!memory) {
        fputs("pp_alloc_crypto: malloc() call failed", stderr);
        abort();
    }
    return memory;
}

#define MAX_BLOCK_SIZE  16  // AES only, block is 128-bit

/// - Parameters:
///   - size: The base number of bytes.
///   - overhead: The extra number of bytes.
/// - Returns: The number of bytes to store a crypto buffer safely.
static inline size_t pp_alloc_crypto_capacity(size_t size, size_t overhead) {

    // encryption, byte-alignment, overhead (e.g. IV, digest)
    return 2 * size + MAX_BLOCK_SIZE + overhead;
}
