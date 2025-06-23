//
//  dp_framing.c
//  Partout
//
//  Created by Davide De Rosa on 6/17/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

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
