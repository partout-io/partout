//
//  control.c
//  Partout
//
//  Created by Davide De Rosa on 6/25/25.
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

#include <assert.h>
#include <string.h>
#include "crypto/allocation.h"
#include "openvpn/control.h"

ctrl_pkt_t *_Nonnull ctrl_pkt_create(packet_code code, uint8_t key, uint32_t packet_id,
                                     const uint8_t *_Nonnull session_id,
                                     const uint8_t *_Nullable payload, size_t payload_len,
                                     const uint32_t *_Nullable ack_ids, size_t ack_ids_len,
                                     const uint8_t *_Nullable ack_remote_session_id) {

    ctrl_pkt_t *pkt = pp_alloc_crypto(sizeof(ctrl_pkt_t));
    pkt->code = code;
    pkt->key = key;
    pkt->packet_id = packet_id;
    pkt->session_id = pp_alloc_crypto(PacketSessionIdLength);
    memcpy(pkt->session_id, session_id, PacketSessionIdLength);
    if (payload) {
        pkt->payload = pp_alloc_crypto(payload_len);
        pkt->payload_len = payload_len;
        memcpy(pkt->payload, payload, payload_len);
    } else {
        pkt->payload = NULL;
        pkt->payload_len = 0;
    }
    if (ack_ids) {
        assert(ack_remote_session_id);
        const size_t ack_len = ack_ids_len * sizeof(uint32_t);
        pkt->ack_ids = pp_alloc_crypto(ack_len);
        pkt->ack_ids_len = ack_ids_len;
        memcpy(pkt->ack_ids, ack_ids, ack_len);
        pkt->ack_remote_session_id = pp_alloc_crypto(PacketSessionIdLength);
        memcpy(pkt->ack_remote_session_id, ack_remote_session_id, PacketSessionIdLength);
    } else {
        pkt->ack_ids = NULL;
        pkt->ack_ids_len = 0;
        pkt->ack_remote_session_id = NULL;
    }
    return pkt;
}

void ctrl_pkt_free(ctrl_pkt_t *_Nonnull pkt) {
    if (!pkt) return;
    if (pkt->session_id) {
        free(pkt->session_id);
    }
    if (pkt->payload) {
        free(pkt->payload);
    }
    if (pkt->ack_ids) {
        free(pkt->ack_ids);
    }
    if (pkt->ack_remote_session_id) {
        free(pkt->ack_remote_session_id);
    }
    free(pkt);
}

// MARK: - Plain

static inline
size_t ctrl_pkt_is_ack(const ctrl_pkt_t *pkt) {
    return pkt->packet_id == UINT32_MAX;
}

static inline
size_t ctrl_pkt_raw_capacity(const ctrl_pkt_t *pkt) {
    const bool is_ack = ctrl_pkt_is_ack(pkt);
    assert(!is_ack || pkt->ack_ids);//, @"Ack packet must provide positive ackLength");
    size_t n = PacketAckLengthLength;
    if (pkt->ack_ids) {
        n += pkt->ack_ids_len * PacketIdLength + PacketSessionIdLength;
    }
    if (!is_ack) {
        n += PacketIdLength;
    }
    n += pkt->payload_len;
    return n;
}

size_t ctrl_pkt_capacity(const ctrl_pkt_t *pkt) {
    const size_t raw_capacity = ctrl_pkt_raw_capacity(pkt);
    return PacketOpcodeLength + PacketSessionIdLength + raw_capacity;
}

size_t ctrl_pkt_capacity_alg(const ctrl_pkt_t *pkt, const ctrl_pkt_alg *alg) {
    const size_t plain_capacity = ctrl_pkt_capacity(pkt);
    const size_t enc_capacity = crypto_encryption_capacity(alg->crypto, plain_capacity);
    const size_t header_len = PacketOpcodeLength + PacketSessionIdLength + PacketReplayIdLength + PacketReplayTimestampLength;
    return header_len + enc_capacity;
}

size_t ctrl_pkt_serialize(uint8_t *_Nonnull dst, const ctrl_pkt_t *_Nonnull pkt) {
    uint8_t *ptr = dst;
    if (pkt->ack_ids) {
        *ptr = pkt->ack_ids_len;
        ptr += PacketAckLengthLength;
        for (size_t i = 0; i < pkt->ack_ids_len; ++i) {
            const uint32_t ack_id = pkt->ack_ids[i];
            *(uint32_t *)ptr = endian_htonl(ack_id);
            ptr += PacketIdLength;
        }
        assert(pkt->ack_remote_session_id);
        memcpy(ptr, pkt->ack_remote_session_id, PacketSessionIdLength);
        ptr += PacketSessionIdLength;
    } else {
        *ptr = 0; // no acks
        ptr += PacketAckLengthLength;
    }
    if (pkt->code != PacketCodeAckV1) {
        *(uint32_t *)ptr = endian_htonl(pkt->packet_id);
        ptr += PacketIdLength;
        if (pkt->payload) {
            memcpy(ptr, pkt->payload, pkt->payload_len);
            ptr += pkt->payload_len;
        }
    }
    return ptr - dst;
}

// MARK: - Auth

size_t ctrl_pkt_serialize_auth(uint8_t *dst,
                               size_t dst_buf_len,
                               const ctrl_pkt_t *pkt,
                               ctrl_pkt_alg *alg,
                               crypto_error_code *error) {

    const size_t digest_len = alg->crypto->base.meta.digest_len;
    uint8_t *ptr = dst + digest_len;
    const uint8_t *subject = ptr;
    *(uint32_t *)ptr = endian_htonl(alg->replay_id);
    ptr += PacketReplayIdLength;
    *(uint32_t *)ptr = endian_htonl(alg->timestamp);
    ptr += PacketReplayTimestampLength;
    ptr += packet_header_set(ptr, pkt->code, pkt->key, pkt->session_id);
    ptr += ctrl_pkt_serialize(ptr, pkt);

    const size_t subject_len = ptr - subject;
    const size_t dst_len = crypto_encrypt(alg->crypto,
                                          dst,
                                          dst_buf_len,
                                          subject,
                                          subject_len,
                                          NULL,
                                          error);
    if (!dst_len) {
        return 0;
    }
    assert(dst_len == digest_len + subject_len);//, @"Encrypted packet size != (Digest + Subject)");
    data_swap(dst, digest_len + PacketReplayIdLength + PacketReplayTimestampLength, PacketOpcodeLength + PacketSessionIdLength);
    return dst_len;
}

// MARK: - Crypt

size_t ctrl_pkt_serialize_crypt(uint8_t *dst,
                                size_t dst_buf_len,
                                const ctrl_pkt_t *pkt,
                                ctrl_pkt_alg *alg,
                                crypto_error_code *error) {

    uint8_t *ptr = dst;
    ptr += packet_header_set(dst, pkt->code, pkt->key, pkt->session_id);
    *(uint32_t *)ptr = endian_htonl(alg->replay_id);
    ptr += PacketReplayIdLength;
    *(uint32_t *)ptr = endian_htonl(alg->timestamp);
    ptr += PacketReplayTimestampLength;

    const size_t ad_len = ptr - dst;
    const crypto_flags_t flags = { NULL, 0, dst, ad_len, false };

    const size_t raw_capacity = ctrl_pkt_raw_capacity(pkt);
    zeroing_data_t *msg = zd_create(raw_capacity);
    ctrl_pkt_serialize(msg->bytes, pkt);
    const size_t enc_msg_len = crypto_encrypt(alg->crypto,
                                              dst + ad_len,
                                              dst_buf_len - ad_len,
                                              msg->bytes,
                                              msg->length,
                                              &flags,
                                              error);
    if (!enc_msg_len) {
        zd_free(msg);
        return 0;
    }
    zd_free(msg);
    return ad_len + enc_msg_len;
}
