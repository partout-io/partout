//
//  replay.h
//  Partout
//
//  Created by Davide De Rosa on 6/19/25.
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
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//      Copyright (c) 2018-Present Private Internet Access
//
//      Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
//      The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//      THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "crypto_openssl/allocation.h"
#include "crypto_openssl/crypto.h"

typedef struct {
    uint32_t highest_pid;
    uint32_t *_Nonnull bitmap;
} replay_t;

#define REPLAY_HIDDEN_WINSIZE           128
#define REPLAY_BITMAP_LEN               (REPLAY_HIDDEN_WINSIZE / 32)
#define REPLAY_BITMAP_INDEX_MASK        (REPLAY_BITMAP_LEN - 1)
#define REPLAY_REDUNDANT_BIT_SHIFTS     5
#define REPLAY_REDUNDANT_BITS           (1 << REPLAY_REDUNDANT_BIT_SHIFTS)
#define REPLAY_BITMAP_LOC_MASK          (REPLAY_REDUNDANT_BITS - 1)
#define REPLAY_WINSIZE                  (REPLAY_HIDDEN_WINSIZE - REPLAY_REDUNDANT_BITS)

static inline
replay_t *_Nonnull replay_create() {
    replay_t *rp = pp_alloc_crypto(sizeof(replay_t));
    rp->highest_pid = 0;
    rp->bitmap =  pp_alloc_crypto(REPLAY_BITMAP_LEN * sizeof(uint32_t));
    return rp;
}

static inline
void replay_free(replay_t *_Nonnull rp) {
    if (!rp) return;
    free(rp->bitmap);
    free(rp);
}

static inline
bool replay_is_replayed(replay_t *_Nonnull rp, uint32_t packet_id) {
    if (packet_id == 0) {
        return true;
    }
    if (REPLAY_WINSIZE + packet_id < rp->highest_pid) {
        return true;
    }

    uint32_t p_index = (packet_id >> REPLAY_REDUNDANT_BIT_SHIFTS);

    if (packet_id > rp->highest_pid) {
        const uint32_t curr_index = rp->highest_pid >> REPLAY_REDUNDANT_BIT_SHIFTS;
        const uint32_t diff = MIN(p_index - curr_index, REPLAY_BITMAP_LEN);

        for (uint32_t bid = 0; bid < diff; ++bid) {
            rp->bitmap[(bid + curr_index + 1) & REPLAY_BITMAP_INDEX_MASK] = 0;
        }

        // side-effect
        rp->highest_pid = packet_id;
    }

    p_index &= REPLAY_BITMAP_INDEX_MASK;
    const uint32_t bit_loc = packet_id & REPLAY_BITMAP_LOC_MASK;
    const uint32_t bitmask = (1 << bit_loc);

    if (rp->bitmap[p_index] & bitmask) {
        return true;
    }
    rp->bitmap[p_index] |= bitmask;
    return false;
}
