//
//  obf.h
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

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "crypto/zeroing_data.h"

typedef enum {
    OBFMethodNone,
    OBFMethodXORMask,
    OBFMethodXORPtrPos,
    OBFMethodReverse,
    OBFMethodXORObfuscate
} obf_method;

typedef struct {
    uint8_t *_Nonnull dst;
    size_t dst_offset;
    const uint8_t *_Nonnull src;
    size_t src_offset;
    size_t src_len;
    const uint8_t *_Nullable mask;
    size_t mask_len;
} obf_alg_ctx;

typedef void (*obf_algorithm)(const obf_alg_ctx *_Nonnull);

typedef struct {
    zeroing_data_t *_Nullable mask;
    obf_algorithm _Nonnull recv; // loop until 0
    obf_algorithm _Nonnull send;
} obf_t;

obf_t *_Nonnull obf_create(obf_method method,
                           const uint8_t *_Nullable mask,
                           size_t mask_len);
void obf_free(obf_t *_Nonnull obf);

static inline
void obf_recv(const obf_t *_Nonnull obf,
              uint8_t *_Nonnull dst,
              const uint8_t *_Nonnull src,
              size_t src_len) {

    const obf_alg_ctx ctx = {
        dst, 0,
        src, 0, src_len,
        obf->mask ? obf->mask->bytes : NULL,
        obf->mask ? obf->mask->length : 0
    };
    obf->recv(&ctx);
}

static inline
void obf_send(const obf_t *_Nonnull obf,
              uint8_t *_Nonnull dst,
              const uint8_t *_Nonnull src,
              size_t src_len) {

    const obf_alg_ctx ctx = {
        dst, 0,
        src, 0, src_len,
        obf->mask ? obf->mask->bytes : NULL,
        obf->mask ? obf->mask->length : 0
    };
    obf->send(&ctx);
}
