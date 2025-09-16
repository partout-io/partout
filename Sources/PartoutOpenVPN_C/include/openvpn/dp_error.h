/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include "crypto/crypto.h"

typedef enum {
    OpenVPNDataPathErrorNone,
    OpenVPNDataPathErrorPeerIdMismatch,
    OpenVPNDataPathErrorCompression,
    OpenVPNDataPathErrorCrypto
} openvpn_dp_error_code;

typedef struct {
    openvpn_dp_error_code dp_code;
    pp_crypto_error_code crypto_code;
} openvpn_dp_error;
