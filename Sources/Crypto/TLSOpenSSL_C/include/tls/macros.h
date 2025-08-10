/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#define PP_CRYPTO_SET_ERROR(crypto_code)\
if (error) *error = crypto_code;\
