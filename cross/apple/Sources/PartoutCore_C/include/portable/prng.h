/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once
#include "conditionals.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#pragma clang assume_nonnull begin

uint32_t pp_prng_rand(void);
bool pp_prng_do(uint8_t *dst, size_t len);

#pragma clang assume_nonnull end
