/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint8_t *_Nonnull bytes;
    size_t length;
} zeroing_data_t;

// MARK: Creation

zeroing_data_t *_Nonnull zd_create(size_t length);
zeroing_data_t *_Nonnull zd_create_with_uint8(uint8_t value);
zeroing_data_t *_Nonnull zd_create_with_uint16(uint16_t value);
zeroing_data_t *_Nonnull zd_create_from_data(const uint8_t *_Nonnull data, size_t length);
zeroing_data_t *_Nonnull zd_create_from_data_range(const uint8_t *_Nonnull data, size_t offset, size_t length);
zeroing_data_t *_Nonnull zd_create_from_string(const char *_Nonnull string, bool null_terminated);
void zd_free(zeroing_data_t *_Nonnull zd);

// MARK: Properties

static inline
const uint8_t *_Nonnull zd_bytes(const zeroing_data_t *_Nonnull zd) {
    return zd->bytes;
}

static inline
uint8_t *_Nonnull zd_mutable_bytes(zeroing_data_t *_Nonnull zd) {
    return zd->bytes;
}

static inline
size_t zd_length(const zeroing_data_t *_Nonnull zd) {
    return zd->length;
}

static inline
bool zd_equals(const zeroing_data_t *_Nonnull zd1, const zeroing_data_t *_Nonnull zd2) {
    return (zd1->length == zd2->length) && (memcmp(zd1->bytes, zd2->bytes, zd1->length) == 0);
}

static inline
bool zd_equals_to_data(const zeroing_data_t *_Nonnull zd1, const uint8_t *_Nonnull data, size_t length) {
    return (zd1->length == length) && (memcmp(zd1->bytes, data, length) == 0);
}

// MARK: Copy

zeroing_data_t *_Nonnull zd_make_copy(const zeroing_data_t *_Nonnull zd);
zeroing_data_t *_Nullable zd_make_slice(const zeroing_data_t *_Nonnull zd, size_t offset, size_t length);

// MARK: Side effect

void zd_append(zeroing_data_t *_Nonnull zd, const zeroing_data_t *_Nonnull other);
void zd_resize(zeroing_data_t *_Nonnull zd, size_t new_length);
void zd_remove_until(zeroing_data_t *_Nonnull zd, size_t offset);
void zd_zero(zeroing_data_t *_Nonnull zd);

// MARK: Accessors

uint16_t zd_uint16(const zeroing_data_t *_Nonnull zd, size_t offset);
