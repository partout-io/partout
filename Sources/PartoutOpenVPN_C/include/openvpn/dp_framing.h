/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "openvpn/comp.h"
#include "openvpn/dp_error.h"

typedef struct {
    uint8_t *_Nonnull dst;
    int *_Nonnull dst_len_offset;
    const uint8_t *_Nonnull src;
    size_t src_len;
    uint16_t mss_val;
} openvpn_dp_framing_assemble_ctx;

typedef struct {
    uint8_t *_Nonnull dst_payload;
    size_t *_Nonnull dst_payload_offset;
    uint8_t *_Nonnull dst_header;
    size_t *_Nonnull dst_header_len;
    const uint8_t *_Nonnull src;
    size_t src_len;
    openvpn_dp_error *_Nullable error;
} openvpn_dp_framing_parse_ctx;

typedef void (*openvpn_dp_framing_assemble_fn)(openvpn_dp_framing_assemble_ctx *_Nonnull);
typedef bool (*openvpn_dp_framing_parse_fn)(openvpn_dp_framing_parse_ctx *_Nonnull);
typedef size_t (*openvpn_dp_framing_capacity_t)(size_t);

typedef struct {
    openvpn_dp_framing_assemble_fn _Nonnull assemble;
    openvpn_dp_framing_parse_fn _Nonnull parse;
} openvpn_dp_framing;

const openvpn_dp_framing *_Nonnull openvpn_dp_framing_of(openvpn_compression_framing comp_f);

// assembled payloads may add up to 2 bytes
static inline
size_t openvpn_dp_framing_assemble_capacity(size_t len) {
    return 2 + len;
}
