/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "partout.h"
#include "portable/portable.h"

#if PARTOUT_HAS_CRYPTO
#include "crypto/crypto.h"
#endif

#if PARTOUT_OPENVPN
#include "openvpn/openvpn.h"
#endif
#if PARTOUT_WIREGUARD
#include "wireguard/backend.h"
#include "wireguard/wireguard.h"
#endif
