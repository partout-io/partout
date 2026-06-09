/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdint.h>

#pragma clang assume_nonnull begin

void openvpn_mss_fix(uint8_t *data, size_t data_len, uint16_t mtu);

#pragma clang assume_nonnull end
