/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#pragma clang assume_nonnull begin

typedef struct {
    uint8_t *bytes;
    size_t length;
} pp_zd;

// MARK: Creation

pp_zd *pp_zd_create(size_t length);
pp_zd *pp_zd_create_with_uint8(uint8_t value);
pp_zd *pp_zd_create_with_uint16(uint16_t value);
pp_zd *pp_zd_create_from_data(const uint8_t *data, size_t length);
pp_zd *pp_zd_create_from_data_range(const uint8_t *data, size_t offset, size_t length);
pp_zd *pp_zd_create_from_string(const char *string, bool null_terminated);
pp_zd *_Nullable pp_zd_create_from_hex(const char *hex);
void pp_zd_free(pp_zd *zd);

// MARK: Properties

static inline
const uint8_t *pp_zd_bytes(const pp_zd *zd) {
    return zd->bytes;
}

static inline
uint8_t *pp_zd_mutable_bytes(pp_zd *zd) {
    return zd->bytes;
}

static inline
size_t pp_zd_length(const pp_zd *zd) {
    return zd->length;
}

static inline
bool pp_zd_equals(const pp_zd *zd1, const pp_zd *zd2) {
    return (zd1->length == zd2->length) && (memcmp(zd1->bytes, zd2->bytes, zd1->length) == 0);
}

static inline
bool pp_zd_equals_to_data(const pp_zd *zd1, const uint8_t *data, size_t length) {
    return (zd1->length == length) && (memcmp(zd1->bytes, data, length) == 0);
}

// MARK: Copy

pp_zd *pp_zd_make_copy(const pp_zd *zd);
pp_zd *_Nullable pp_zd_make_slice(const pp_zd *zd, size_t offset, size_t length);

// MARK: Side effect

void pp_zd_append(pp_zd *zd, const pp_zd *other);
void pp_zd_resize(pp_zd *zd, size_t new_length);
void pp_zd_remove_until(pp_zd *zd, size_t offset);
void pp_zd_zero(pp_zd *zd);

// MARK: Accessors

uint16_t pp_zd_uint16(const pp_zd *zd, size_t offset);

#pragma clang assume_nonnull end
