/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdlib.h>
#include <string.h>
#include "crypto/allocation.h"
#include "crypto/zeroing_data.h"

// TODO: ###, make zd inline

// MARK: Creation

zeroing_data_t *zd_create(size_t length) {
    zeroing_data_t *zd = pp_alloc_crypto(sizeof(zeroing_data_t));
    zd->bytes = pp_alloc_crypto(length);
    zd->length = length;
    return zd;
}

zeroing_data_t *zd_create_copy(const uint8_t *bytes, size_t length) {
    zeroing_data_t *zd = pp_alloc_crypto(sizeof(zeroing_data_t));
    zd->bytes = pp_alloc_crypto(length);
    memcpy(zd->bytes, bytes, length);
    zd->length = length;
    return zd;
}

zeroing_data_t *zd_create_with_uint8(uint8_t value) {
    zeroing_data_t *zd = pp_alloc_crypto(sizeof(zeroing_data_t));
    zd->bytes = pp_alloc_crypto(1);
    zd->bytes[0] = value;
    zd->length = 1;
    return zd;
}

zeroing_data_t *zd_create_with_uint16(uint16_t value) {
    zeroing_data_t *zd = pp_alloc_crypto(sizeof(zeroing_data_t));
    zd->bytes = pp_alloc_crypto(2);
    zd->bytes[0] = value & 0xFF;
    zd->bytes[1] = value >> 8;
    zd->length = 2;
    return zd;
}

zeroing_data_t *zd_create_from_data(const uint8_t *data, size_t length) {
    return zd_create_copy(data, length);
}

zeroing_data_t *zd_create_from_data_range(const uint8_t *data, size_t offset, size_t length) {
    return zd_create_copy(data + offset, length);
}

zeroing_data_t *zd_create_from_string(const char *string, bool null_terminated) {
    size_t len = strlen(string);
    if (null_terminated) {
        return zd_create_copy((const uint8_t *)string, len + 1);
    } else {
        return zd_create_copy((const uint8_t *)string, len);
    }
}

zeroing_data_t *zd_create_from_hex(const char *hex) {
    const size_t len = strlen(hex);
    if (len & 1) return NULL;
    const size_t bytes_len = len / 2;
    uint8_t *bytes = pp_alloc_crypto(bytes_len);
    for (size_t i = 0; i < bytes_len; i++) {
        sscanf(hex + 2 * i, "%2hhx", bytes + i);
    }
    return zd_create_copy(bytes, bytes_len);
}

void zd_free(zeroing_data_t *zd) {
    if (!zd) return;

    pp_zero(zd->bytes, zd->length);
    free(zd->bytes);
    free(zd);
}

// MARK: Copy

zeroing_data_t *zd_make_copy(const zeroing_data_t *zd) {
    pp_assert(zd);
    return zd_create_copy(zd->bytes, zd->length);
}

zeroing_data_t *zd_make_slice(const zeroing_data_t *zd, size_t offset, size_t length) {
    pp_assert(zd);
    if (offset + length > zd->length) return NULL;

    zeroing_data_t *slice = pp_alloc_crypto(sizeof(zeroing_data_t));
    slice->bytes = pp_alloc_crypto(length);
    memcpy(slice->bytes, zd->bytes + offset, length);
    slice->length = length;
    return slice;
}

// MARK: Side effect

void zd_append(zeroing_data_t *zd, const zeroing_data_t *other) {
    pp_assert(zd);
    size_t new_len = zd->length + other->length;
    uint8_t *new_bytes = pp_alloc_crypto(new_len);
    memcpy(new_bytes, zd->bytes, zd->length);
    memcpy(new_bytes + zd->length, other->bytes, other->length);

    pp_zero(zd->bytes, zd->length);
    free(zd->bytes);
    zd->bytes = new_bytes;
    zd->length = new_len;
}

void zd_resize(zeroing_data_t *zd, size_t new_length) {
    pp_assert(zd);
    if (new_length == zd->length) return;

    uint8_t *new_bytes = pp_alloc_crypto(new_length);
    if (new_length < zd->length) {
        memcpy(new_bytes, zd->bytes, new_length);
    } else {
        memcpy(new_bytes, zd->bytes, zd->length);
        pp_zero(new_bytes + zd->length, new_length - zd->length);
    }
    pp_zero(zd->bytes, zd->length);
    free(zd->bytes);

    zd->bytes = new_bytes;
    zd->length = new_length;
}

void zd_remove_until(zeroing_data_t *zd, size_t offset) {
    pp_assert(zd);
    if (offset > zd->length) return;

    size_t new_length = zd->length - offset;
    uint8_t *new_bytes = pp_alloc_crypto(new_length);
    memcpy(new_bytes, zd->bytes + offset, new_length);

    pp_zero(zd->bytes, zd->length);
    free(zd->bytes);

    zd->bytes = new_bytes;
    zd->length = new_length;
}

void zd_zero(zeroing_data_t *zd) {
    pp_assert(zd);
    pp_zero(zd->bytes, zd->length);
}

// MARK: Accessors

uint16_t zd_uint16(const zeroing_data_t *zd, size_t offset) {
    pp_assert(zd);
    if (offset + 2 > zd->length) return 0;
    return zd->bytes[offset] | (zd->bytes[offset + 1] << 8);
}
