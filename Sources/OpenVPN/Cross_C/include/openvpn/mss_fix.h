/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdint.h>

void mss_fix(uint8_t *_Nonnull data, size_t data_len, uint16_t mtu);
