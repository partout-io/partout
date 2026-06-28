/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "partout.h"
#include "crypto/crypto.h"
#include "portable/portable.h"
#include "crypto/tls.h"

#if PARTOUT_OPENVPN
#include "openvpn/openvpn.h"
#endif
#if PARTOUT_WIREGUARD
#include "wireguard/backend.h"
#include "wireguard/wireguard.h"
#endif
