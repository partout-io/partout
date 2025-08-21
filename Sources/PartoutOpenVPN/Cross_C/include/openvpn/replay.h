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

#define OpenVPNReplayHiddenWinSize              128
#define OpenVPNReplayBitmapLength               (OpenVPNReplayHiddenWinSize / 32)
#define OpenVPNReplayBitmapIndexMask            (OpenVPNReplayBitmapLength - 1)
#define OpenVPNReplayRedundantBitShifts         5
#define OpenVPNReplayRedundantBits              (1 << OpenVPNReplayRedundantBitShifts)
#define OpenVPNReplayBitmapLocMask              (OpenVPNReplayRedundantBits - 1)
#define OpenVPNReplayWinSize                    (OpenVPNReplayHiddenWinSize - OpenVPNReplayRedundantBits)

static inline
openvpn_replay *_Nonnull openvpn_replay_create() {
    openvpn_replay *rp = pp_alloc(sizeof(openvpn_replay));
    rp->highest_pid = 0;
    rp->bitmap =  pp_alloc(OpenVPNReplayBitmapLength * sizeof(uint32_t));
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
    if (OpenVPNReplayWinSize + packet_id < rp->highest_pid) {
        return true;
    }

    uint32_t p_index = (packet_id >> OpenVPNReplayRedundantBitShifts);

    if (packet_id > rp->highest_pid) {
        const uint32_t curr_index = rp->highest_pid >> OpenVPNReplayRedundantBitShifts;
        const uint32_t diff = MIN(p_index - curr_index, OpenVPNReplayBitmapLength);

        for (uint32_t bid = 0; bid < diff; ++bid) {
            rp->bitmap[(bid + curr_index + 1) & OpenVPNReplayBitmapIndexMask] = 0;
        }

        // side-effect
        rp->highest_pid = packet_id;
    }

    p_index &= OpenVPNReplayBitmapIndexMask;
    const uint32_t bit_loc = packet_id & OpenVPNReplayBitmapLocMask;
    const uint32_t bitmask = (1 << bit_loc);

    if (rp->bitmap[p_index] & bitmask) {
        return true;
    }
    rp->bitmap[p_index] |= bitmask;
    return false;
}
