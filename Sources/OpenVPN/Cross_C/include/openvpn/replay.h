/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "portable/common.h"
#include "crypto/crypto.h"

typedef struct {
    uint32_t highest_pid;
    uint32_t *_Nonnull bitmap;
} openvpn_replay;

#define OPENVPN_REPLAY_HIDDEN_WINSIZE           128
#define OPENVPN_REPLAY_BITMAP_LEN               (OPENVPN_REPLAY_HIDDEN_WINSIZE / 32)
#define OPENVPN_REPLAY_BITMAP_INDEX_MASK        (OPENVPN_REPLAY_BITMAP_LEN - 1)
#define OPENVPN_REPLAY_REDUNDANT_BIT_SHIFTS     5
#define OPENVPN_REPLAY_REDUNDANT_BITS           (1 << OPENVPN_REPLAY_REDUNDANT_BIT_SHIFTS)
#define OPENVPN_REPLAY_BITMAP_LOC_MASK          (OPENVPN_REPLAY_REDUNDANT_BITS - 1)
#define OPENVPN_REPLAY_WINSIZE                  (OPENVPN_REPLAY_HIDDEN_WINSIZE - OPENVPN_REPLAY_REDUNDANT_BITS)

static inline
openvpn_replay *_Nonnull openvpn_replay_create() {
    openvpn_replay *rp = pp_alloc_crypto(sizeof(openvpn_replay));
    rp->highest_pid = 0;
    rp->bitmap =  pp_alloc_crypto(OPENVPN_REPLAY_BITMAP_LEN * sizeof(uint32_t));
    return rp;
}

static inline
void openvpn_replay_free(openvpn_replay *_Nonnull rp) {
    if (!rp) return;
    free(rp->bitmap);
    free(rp);
}

static inline
bool openvpn_replay_is_replayed(openvpn_replay *_Nonnull rp, uint32_t packet_id) {
    if (packet_id == 0) {
        return true;
    }
    if (OPENVPN_REPLAY_WINSIZE + packet_id < rp->highest_pid) {
        return true;
    }

    uint32_t p_index = (packet_id >> OPENVPN_REPLAY_REDUNDANT_BIT_SHIFTS);

    if (packet_id > rp->highest_pid) {
        const uint32_t curr_index = rp->highest_pid >> OPENVPN_REPLAY_REDUNDANT_BIT_SHIFTS;
        const uint32_t diff = MIN(p_index - curr_index, OPENVPN_REPLAY_BITMAP_LEN);

        for (uint32_t bid = 0; bid < diff; ++bid) {
            rp->bitmap[(bid + curr_index + 1) & OPENVPN_REPLAY_BITMAP_INDEX_MASK] = 0;
        }

        // side-effect
        rp->highest_pid = packet_id;
    }

    p_index &= OPENVPN_REPLAY_BITMAP_INDEX_MASK;
    const uint32_t bit_loc = packet_id & OPENVPN_REPLAY_BITMAP_LOC_MASK;
    const uint32_t bitmask = (1 << bit_loc);

    if (rp->bitmap[p_index] & bitmask) {
        return true;
    }
    rp->bitmap[p_index] |= bitmask;
    return false;
}
