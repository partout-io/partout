/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

typedef enum {
    OpenVPNCompressionFramingDisabled,     // no option
    OpenVPNCompressionFramingCompLZO,      // --comp-lzo
    OpenVPNCompressionFramingCompress,     // --compress stub
    OpenVPNCompressionFramingCompressV2    // --compress stub-v2
} openvpn_compression_framing;
