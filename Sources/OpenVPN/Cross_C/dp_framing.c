/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "openvpn/dp_framing_comp.h"

static const dp_framing_t comp_disabled = {
    dp_framing_assemble_disabled,
    dp_framing_parse_disabled
};

static const dp_framing_t comp_lzo = {
    dp_framing_assemble_lzo,
    dp_framing_parse_lzo
};

static const dp_framing_t comp_compress = {
    dp_framing_assemble_compress,
    dp_framing_parse_compress
};

static const dp_framing_t comp_compress_v2 = {
    dp_framing_assemble_compress_v2,
    dp_framing_parse_compress_v2
};

const dp_framing_t *dp_framing(compression_framing_t comp_f) {
    switch (comp_f) {
    case CompressionFramingDisabled:
        return &comp_disabled;
    case CompressionFramingCompLZO:
        return &comp_lzo;
    case CompressionFramingCompress:
        return &comp_compress;
    case CompressionFramingCompressV2:
        return &comp_compress_v2;
    }
}
