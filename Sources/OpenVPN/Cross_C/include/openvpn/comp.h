/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

typedef enum {
    CompressionFramingDisabled,     // no option
    CompressionFramingCompLZO,      // --comp-lzo
    CompressionFramingCompress,     // --compress stub
    CompressionFramingCompressV2    // --compress stub-v2
} compression_framing_t;
