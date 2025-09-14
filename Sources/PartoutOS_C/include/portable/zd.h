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
} pp_zd;

// MARK: Creation

pp_zd *_Nonnull pp_zd_create(size_t length);
pp_zd *_Nonnull pp_zd_create_with_uint8(uint8_t value);
pp_zd *_Nonnull pp_zd_create_with_uint16(uint16_t value);
pp_zd *_Nonnull pp_zd_create_from_data(const uint8_t *_Nonnull data, size_t length);
pp_zd *_Nonnull pp_zd_create_from_data_range(const uint8_t *_Nonnull data, size_t offset, size_t length);
pp_zd *_Nonnull pp_zd_create_from_string(const char *_Nonnull string, bool null_terminated);
pp_zd *_Nullable pp_zd_create_from_hex(const char *_Nonnull hex);
void pp_zd_free(pp_zd *_Nonnull zd);

// MARK: Properties

static inline
const uint8_t *_Nonnull pp_zd_bytes(const pp_zd *_Nonnull zd) {
    return zd->bytes;
}

static inline
uint8_t *_Nonnull pp_zd_mutable_bytes(pp_zd *_Nonnull zd) {
    return zd->bytes;
}

static inline
size_t pp_zd_length(const pp_zd *_Nonnull zd) {
    return zd->length;
}

static inline
bool pp_zd_equals(const pp_zd *_Nonnull zd1, const pp_zd *_Nonnull zd2) {
    return (zd1->length == zd2->length) && (memcmp(zd1->bytes, zd2->bytes, zd1->length) == 0);
}

static inline
bool pp_zd_equals_to_data(const pp_zd *_Nonnull zd1, const uint8_t *_Nonnull data, size_t length) {
    return (zd1->length == length) && (memcmp(zd1->bytes, data, length) == 0);
}

// MARK: Copy

pp_zd *_Nonnull pp_zd_make_copy(const pp_zd *_Nonnull zd);
pp_zd *_Nullable pp_zd_make_slice(const pp_zd *_Nonnull zd, size_t offset, size_t length);

// MARK: Side effect

void pp_zd_append(pp_zd *_Nonnull zd, const pp_zd *_Nonnull other);
void pp_zd_resize(pp_zd *_Nonnull zd, size_t new_length);
void pp_zd_remove_until(pp_zd *_Nonnull zd, size_t offset);
void pp_zd_zero(pp_zd *_Nonnull zd);

// MARK: Accessors

uint16_t pp_zd_uint16(const pp_zd *_Nonnull zd, size_t offset);
