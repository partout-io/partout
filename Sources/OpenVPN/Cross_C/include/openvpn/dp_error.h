/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto/crypto.h"

typedef enum {
    DataPathErrorNone,
    DataPathErrorPeerIdMismatch,
    DataPathErrorCompression,
    DataPathErrorCrypto
} dp_error_code;

typedef struct {
    dp_error_code dp_code;
    crypto_error_code crypto_code;
} dp_error_t;
