/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdlib.h>
#include <string.h>
#include "portable/common.h"
#include "portable/zd.h"

// TODO: #155, make zd inline

// MARK: Creation

pp_zd *pp_zd_create(size_t length) {
    pp_zd *zd = pp_alloc(sizeof(pp_zd));
    zd->bytes = pp_alloc(length);
    zd->length = length;
    return zd;
}

pp_zd *pp_zd_create_copy(const uint8_t *bytes, size_t length) {
    pp_zd *zd = pp_alloc(sizeof(pp_zd));
    zd->bytes = pp_alloc(length);
    memcpy(zd->bytes, bytes, length);
    zd->length = length;
    return zd;
}

pp_zd *pp_zd_create_with_uint8(uint8_t value) {
    pp_zd *zd = pp_alloc(sizeof(pp_zd));
    zd->bytes = pp_alloc(1);
    zd->bytes[0] = value;
    zd->length = 1;
    return zd;
}

pp_zd *pp_zd_create_with_uint16(uint16_t value) {
    pp_zd *zd = pp_alloc(sizeof(pp_zd));
    zd->bytes = pp_alloc(2);
    zd->bytes[0] = value & 0xFF;
    zd->bytes[1] = value >> 8;
    zd->length = 2;
    return zd;
}

pp_zd *pp_zd_create_from_data(const uint8_t *data, size_t length) {
    return pp_zd_create_copy(data, length);
}

pp_zd *pp_zd_create_from_data_range(const uint8_t *data, size_t offset, size_t length) {
    return pp_zd_create_copy(data + offset, length);
}

pp_zd *pp_zd_create_from_string(const char *string, bool null_terminated) {
    size_t len = strlen(string);
    if (null_terminated) {
        return pp_zd_create_copy((const uint8_t *)string, len + 1);
    } else {
        return pp_zd_create_copy((const uint8_t *)string, len);
    }
}

pp_zd *pp_zd_create_from_hex(const char *hex) {
    const size_t len = strlen(hex);
    if (len & 1) return NULL;
    const size_t bytes_len = len / 2;
    uint8_t *bytes = pp_alloc(bytes_len);
    for (size_t i = 0; i < bytes_len; i++) {
        pp_sscanf(hex + 2 * i, "%2hhx", bytes + i);
    }
    return pp_zd_create_copy(bytes, bytes_len);
}

void pp_zd_free(pp_zd *zd) {
    if (!zd) return;

    pp_zero(zd->bytes, zd->length);
    free(zd->bytes);
    free(zd);
}

// MARK: Copy

pp_zd *pp_zd_make_copy(const pp_zd *zd) {
    pp_assert(zd);
    return pp_zd_create_copy(zd->bytes, zd->length);
}

pp_zd *pp_zd_make_slice(const pp_zd *zd, size_t offset, size_t length) {
    pp_assert(zd);
    if (offset + length > zd->length) return NULL;

    pp_zd *slice = pp_alloc(sizeof(pp_zd));
    slice->bytes = pp_alloc(length);
    memcpy(slice->bytes, zd->bytes + offset, length);
    slice->length = length;
    return slice;
}

// MARK: Side effect

void pp_zd_append(pp_zd *zd, const pp_zd *other) {
    pp_assert(zd);
    size_t new_len = zd->length + other->length;
    uint8_t *new_bytes = pp_alloc(new_len);
    memcpy(new_bytes, zd->bytes, zd->length);
    memcpy(new_bytes + zd->length, other->bytes, other->length);

    pp_zero(zd->bytes, zd->length);
    free(zd->bytes);
    zd->bytes = new_bytes;
    zd->length = new_len;
}

void pp_zd_resize(pp_zd *zd, size_t new_length) {
    pp_assert(zd);
    if (new_length == zd->length) return;

    uint8_t *new_bytes = pp_alloc(new_length);
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

void pp_zd_remove_until(pp_zd *zd, size_t offset) {
    pp_assert(zd);
    if (offset > zd->length) return;

    size_t new_length = zd->length - offset;
    uint8_t *new_bytes = pp_alloc(new_length);
    memcpy(new_bytes, zd->bytes + offset, new_length);

    pp_zero(zd->bytes, zd->length);
    free(zd->bytes);

    zd->bytes = new_bytes;
    zd->length = new_length;
}

void pp_zd_zero(pp_zd *zd) {
    pp_assert(zd);
    pp_zero(zd->bytes, zd->length);
}

// MARK: Accessors

uint16_t pp_zd_uint16(const pp_zd *zd, size_t offset) {
    pp_assert(zd);
    if (offset + 2 > zd->length) return 0;
    return zd->bytes[offset] | (zd->bytes[offset + 1] << 8);
}
