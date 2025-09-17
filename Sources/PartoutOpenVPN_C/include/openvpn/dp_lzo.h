/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "openvpn/dp_framing.h"
#include "openvpn/lzo.h"

void openvpn_dp_lzo_assemble(openvpn_dp_framing_assemble_ctx *_Nonnull ctx);
bool openvpn_dp_lzo_parse(pp_lzo _Nonnull lzo,
                          openvpn_compression_framing comp_f,
                          uint8_t dst_header,
                          pp_zd *_Nonnull dst,
                          size_t dst_len,
                          bool *_Nonnull is_compressed);
