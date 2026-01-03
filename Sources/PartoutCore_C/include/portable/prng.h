/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

uint32_t pp_prng_rand();
bool pp_prng_do(uint8_t *_Nonnull dst, size_t len);
