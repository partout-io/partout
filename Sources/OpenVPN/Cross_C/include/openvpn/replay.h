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

#define REPLAY_HIDDEN_WINSIZE           128
#define REPLAY_BITMAP_LEN               (REPLAY_HIDDEN_WINSIZE / 32)
#define REPLAY_BITMAP_INDEX_MASK        (REPLAY_BITMAP_LEN - 1)
#define REPLAY_REDUNDANT_BIT_SHIFTS     5
#define REPLAY_REDUNDANT_BITS           (1 << REPLAY_REDUNDANT_BIT_SHIFTS)
#define REPLAY_BITMAP_LOC_MASK          (REPLAY_REDUNDANT_BITS - 1)
#define REPLAY_WINSIZE                  (REPLAY_HIDDEN_WINSIZE - REPLAY_REDUNDANT_BITS)

static inline
openvpn_replay *_Nonnull openvpn_replay_create() {
    openvpn_replay *rp = pp_alloc_crypto(sizeof(openvpn_replay));
    rp->highest_pid = 0;
    rp->bitmap =  pp_alloc_crypto(REPLAY_BITMAP_LEN * sizeof(uint32_t));
    return rp;
}

static inline
void openvpn_replay_free(openvpn_replay *_Nonnull rp) {
    if (!rp) return;
    free(rp->bitmap);
    free(rp);
}

static inline
bool openvpn_replay_is_replayed(openvpn_replay *_Nonnull rp, uint32_t openvpn_packet_id) {
    if (openvpn_packet_id == 0) {
        return true;
    }
    if (REPLAY_WINSIZE + openvpn_packet_id < rp->highest_pid) {
        return true;
    }

    uint32_t p_index = (openvpn_packet_id >> REPLAY_REDUNDANT_BIT_SHIFTS);

    if (openvpn_packet_id > rp->highest_pid) {
        const uint32_t curr_index = rp->highest_pid >> REPLAY_REDUNDANT_BIT_SHIFTS;
        const uint32_t diff = MIN(p_index - curr_index, REPLAY_BITMAP_LEN);

        for (uint32_t bid = 0; bid < diff; ++bid) {
            rp->bitmap[(bid + curr_index + 1) & REPLAY_BITMAP_INDEX_MASK] = 0;
        }

        // side-effect
        rp->highest_pid = openvpn_packet_id;
    }

    p_index &= REPLAY_BITMAP_INDEX_MASK;
    const uint32_t bit_loc = openvpn_packet_id & REPLAY_BITMAP_LOC_MASK;
    const uint32_t bitmask = (1 << bit_loc);

    if (rp->bitmap[p_index] & bitmask) {
        return true;
    }
    rp->bitmap[p_index] |= bitmask;
    return false;
}
