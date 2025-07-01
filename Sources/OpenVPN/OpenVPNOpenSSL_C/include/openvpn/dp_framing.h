//
//  dp_framing.h
//  Partout
//
//  Created by Davide De Rosa on 6/16/25.
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
#include "openvpn/comp.h"
#include "openvpn/dp_error.h"

typedef struct {
    uint8_t *_Nonnull dst;
    size_t *_Nonnull dst_len_offset;
    const uint8_t *_Nonnull src;
    size_t src_len;
    uint16_t mss_val;
} dp_framing_assemble_ctx;

typedef struct {
    uint8_t *_Nonnull dst_payload;
    size_t *_Nonnull dst_payload_offset;
    uint8_t *_Nonnull dst_header;
    size_t *_Nonnull dst_header_len;
    const uint8_t *_Nonnull src;
    size_t src_len;
    dp_error_t *_Nullable error;
} dp_framing_parse_ctx;

typedef void (*dp_framing_assemble_t)(dp_framing_assemble_ctx *_Nonnull);
typedef bool (*dp_framing_parse_t)(dp_framing_parse_ctx *_Nonnull);
typedef size_t (*dp_framing_capacity_t)(size_t);

typedef struct {
    dp_framing_assemble_t _Nonnull assemble;
    dp_framing_parse_t _Nonnull parse;
} dp_framing_t;

const dp_framing_t *_Nonnull dp_framing(compression_framing_t comp_f);

// assembled payloads may add up to 2 bytes
static inline
size_t dp_framing_assemble_capacity(size_t len) {
    return 2 + len;
}
