/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "openvpn/dp_framing_comp.h"

static const openvpn_dp_framing comp_disabled = {
    openvpn_dp_framing_assemble_disabled,
    openvpn_dp_framing_parse_disabled
};

static const openvpn_dp_framing comp_lzo = {
    openvpn_dp_framing_assemble_lzo,
    openvpn_dp_framing_parse_lzo
};

static const openvpn_dp_framing comp_compress = {
    openvpn_dp_framing_assemble_compress,
    openvpn_dp_framing_parse_compress
};

static const openvpn_dp_framing comp_compress_v2 = {
    openvpn_dp_framing_assemble_compress_v2,
    openvpn_dp_framing_parse_compress_v2
};

const openvpn_dp_framing *openvpn_dp_framing_of(openvpn_compression_framing comp_f) {
    switch (comp_f) {
    case OpenVPNCompressionFramingDisabled:
        return &comp_disabled;
    case OpenVPNCompressionFramingCompLZO:
        return &comp_lzo;
    case OpenVPNCompressionFramingCompress:
        return &comp_compress;
    case OpenVPNCompressionFramingCompressV2:
        return &comp_compress_v2;
    }
}
