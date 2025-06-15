//
//  zeroing_data.h
//  Partout
//
//  Created by Davide De Rosa on 6/14/25.
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

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t *bytes;
    size_t length;
} zeroing_data_t;

// MARK: Creation

zeroing_data_t *zd_create(size_t length);
zeroing_data_t *zd_create_copy(const uint8_t *bytes, size_t length);
zeroing_data_t *zd_create_with_uint8(uint8_t value);
zeroing_data_t *zd_create_with_uint16(uint16_t value);
zeroing_data_t *zd_create_from_data(const uint8_t *data, size_t length);
zeroing_data_t *zd_create_from_data_range(const uint8_t *data, size_t offset, size_t length);
zeroing_data_t *zd_create_from_string(const char *string, bool null_terminated);
void zd_free(zeroing_data_t *zd);

// MARK: Properties

const uint8_t *zd_bytes(const zeroing_data_t *zd);
uint8_t *zd_mutable_bytes(zeroing_data_t *zd);
size_t zd_length(const zeroing_data_t *zd);
bool zd_equals(const zeroing_data_t *zd1, const zeroing_data_t *zd2);

// MARK: Copy

zeroing_data_t *zd_make_copy(const zeroing_data_t *zd);
zeroing_data_t *zd_make_slice(const zeroing_data_t *zd, size_t offset, size_t length);

// MARK: Side effect

void zd_append(zeroing_data_t *zd, const zeroing_data_t *other);
void zd_truncate(zeroing_data_t *zd, size_t new_length);
void zd_remove_until(zeroing_data_t *zd, size_t offset);
void zd_zero(zeroing_data_t *zd);

// MARK: Accessors

uint16_t zd_uint16(const zeroing_data_t *zd, size_t offset);
