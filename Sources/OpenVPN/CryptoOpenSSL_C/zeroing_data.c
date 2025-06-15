//
//  zeroing_data.c
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

#include "allocation.h"
#include "zeroing_data.h"
#include <stdlib.h>
#include <string.h>

// MARK: Creation

zeroing_data_t *zd_create(size_t length) {
    zeroing_data_t *zd = pp_alloc_crypto(sizeof(zeroing_data_t));
    zd->bytes = pp_alloc_crypto(length);
    bzero(zd->bytes, length);
    zd->length = length;
    return zd;
}

zeroing_data_t *zd_create_copy(const uint8_t *bytes, size_t length) {
    zeroing_data_t *zd = pp_alloc_crypto(sizeof(zeroing_data_t));
    if (bytes) {
        zd->bytes = pp_alloc_crypto(length);
        memcpy(zd->bytes, bytes, length);
    }
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
    if (!data || length == 0) return NULL;
    return zd_create_copy(data, length);
}

zeroing_data_t *zd_create_from_data_range(const uint8_t *data, size_t offset, size_t length) {
    if (!data || length == 0) return NULL;
    return zd_create_copy(data + offset, length);
}

zeroing_data_t *zd_create_from_string(const char *string, bool null_terminated) {
    if (!string) return NULL;
    size_t len = strlen(string);
    if (null_terminated) {
        return zd_create_copy((const uint8_t *)string, len + 1);
    } else {
        return zd_create_copy((const uint8_t *)string, len);
    }
}

void zd_free(zeroing_data_t *zd) {
    if (zd) {
        if (zd->bytes) {
            bzero(zd->bytes, zd->length);
            free(zd->bytes);
        }
        free(zd);
    }
}

// MARK: Properties

const uint8_t *zd_bytes(const zeroing_data_t *zd) {
    return zd ? zd->bytes : NULL;
}

uint8_t *zd_mutable_bytes(zeroing_data_t *zd) {
    return zd ? zd->bytes : NULL;
}

size_t zd_length(const zeroing_data_t *zd) {
    return zd ? zd->length : 0;
}

bool zd_equals(const zeroing_data_t *zd1, const zeroing_data_t *zd2) {
    if (!zd1 || !zd2) return false;
    return (zd1->length == zd2->length) && (memcmp(zd1->bytes, zd2->bytes, zd1->length) == 0);
}

// MARK: Copy

zeroing_data_t *zd_make_copy(const zeroing_data_t *zd) {
    if (!zd) return NULL;
    return zd_create_copy(zd->bytes, zd->length);
}

zeroing_data_t *zd_make_slice(const zeroing_data_t *zd, size_t offset, size_t length) {
    if (!zd || offset + length > zd->length) return NULL;

    zeroing_data_t *slice = pp_alloc_crypto(sizeof(zeroing_data_t));
    slice->bytes = pp_alloc_crypto(length);
    memcpy(slice->bytes, zd->bytes + offset, length);
    slice->length = length;
    return slice;
}

// MARK: Side effect

void zd_append(zeroing_data_t *zd, const zeroing_data_t *other) {
    if (!zd || !other) return;

    size_t new_len = zd->length + other->length;
    uint8_t *new_bytes = pp_alloc_crypto(new_len);
    memcpy(new_bytes, zd->bytes, zd->length);
    memcpy(new_bytes + zd->length, other->bytes, other->length);

    bzero(zd->bytes, zd->length);
    free(zd->bytes);
    zd->bytes = new_bytes;
    zd->length = new_len;
}

void zd_truncate(zeroing_data_t *zd, size_t new_length) {
    if (!zd || new_length > zd->length) return;

    uint8_t *new_bytes = pp_alloc_crypto(new_length);
    memcpy(new_bytes, zd->bytes, new_length);

    bzero(zd->bytes, zd->length);
    free(zd->bytes);

    zd->bytes = new_bytes;
    zd->length = new_length;
}

void zd_remove_until(zeroing_data_t *zd, size_t offset) {
    if (!zd || offset > zd->length) return;

    size_t new_length = zd->length - offset;
    uint8_t *new_bytes = pp_alloc_crypto(new_length);
    memcpy(new_bytes, zd->bytes + offset, new_length);

    bzero(zd->bytes, zd->length);
    free(zd->bytes);

    zd->bytes = new_bytes;
    zd->length = new_length;
}

void zd_zero(zeroing_data_t *zd) {
    if (zd && zd->bytes) {
        bzero(zd->bytes, zd->length);
    }
}

// MARK: Accessors

uint16_t zd_uint16(const zeroing_data_t *zd, size_t offset) {
    if (!zd || offset + 2 > zd->length) return 0;
    return zd->bytes[offset] | (zd->bytes[offset + 1] << 8);
}
