/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <string.h>
#include "portable/common.h"
#include "openvpn/control.h"

openvpn_ctrl *_Nonnull openvpn_ctrl_create(openvpn_packet_code code, uint8_t key, uint32_t packet_id,
                                     const uint8_t *_Nonnull session_id,
                                     const uint8_t *_Nullable payload, size_t payload_len,
                                     const uint32_t *_Nullable ack_ids, size_t ack_ids_len,
                                     const uint8_t *_Nullable ack_remote_session_id) {

    openvpn_ctrl *pkt = pp_alloc(sizeof(openvpn_ctrl));
    pkt->code = code;
    pkt->key = key;
    pkt->packet_id = packet_id;
    pkt->session_id = pp_alloc(OpenVPNPacketSessionIdLength);
    memcpy(pkt->session_id, session_id, OpenVPNPacketSessionIdLength);
    if (payload) {
        pkt->payload = pp_alloc(payload_len);
        pkt->payload_len = payload_len;
        memcpy(pkt->payload, payload, payload_len);
    } else {
        pkt->payload = NULL;
        pkt->payload_len = 0;
    }
    if (ack_ids) {
        pp_assert(ack_remote_session_id);
        const size_t ack_len = ack_ids_len * sizeof(uint32_t);
        pkt->ack_ids = pp_alloc(ack_len);
        pkt->ack_ids_len = ack_ids_len;
        memcpy(pkt->ack_ids, ack_ids, ack_len);
        pkt->ack_remote_session_id = pp_alloc(OpenVPNPacketSessionIdLength);
        memcpy(pkt->ack_remote_session_id, ack_remote_session_id, OpenVPNPacketSessionIdLength);
    } else {
        pkt->ack_ids = NULL;
        pkt->ack_ids_len = 0;
        pkt->ack_remote_session_id = NULL;
    }
    return pkt;
}

void openvpn_ctrl_free(openvpn_ctrl *_Nonnull pkt) {
    if (!pkt) return;
    if (pkt->session_id) {
        pp_free(pkt->session_id);
    }
    if (pkt->payload) {
        pp_free(pkt->payload);
    }
    if (pkt->ack_ids) {
        pp_free(pkt->ack_ids);
    }
    if (pkt->ack_remote_session_id) {
        pp_free(pkt->ack_remote_session_id);
    }
    pp_free(pkt);
}

// MARK: - Plain

static inline
size_t openvpn_ctrl_is_ack(const openvpn_ctrl *pkt) {
    return pkt->packet_id == UINT32_MAX;
}

static inline
size_t openvpn_ctrl_raw_capacity(const openvpn_ctrl *pkt) {
    const bool is_ack = openvpn_ctrl_is_ack(pkt);
    pp_assert(!is_ack || pkt->ack_ids);//, @"Ack packet must provide positive ackLength");
    size_t n = OpenVPNPacketAckLengthLength;
    if (pkt->ack_ids) {
        n += pkt->ack_ids_len * OpenVPNPacketIdLength + OpenVPNPacketSessionIdLength;
    }
    if (!is_ack) {
        n += OpenVPNPacketIdLength;
    }
    n += pkt->payload_len;
    return n;
}

size_t openvpn_ctrl_capacity(const openvpn_ctrl *pkt) {
    const size_t raw_capacity = openvpn_ctrl_raw_capacity(pkt);
    return OpenVPNPacketOpcodeLength + OpenVPNPacketSessionIdLength + raw_capacity;
}

size_t openvpn_ctrl_capacity_alg(const openvpn_ctrl *pkt, const openvpn_ctrl_alg *alg) {
    const size_t plain_capacity = openvpn_ctrl_capacity(pkt);
    const size_t enc_capacity = pp_crypto_encryption_capacity(alg->crypto, plain_capacity);
    const size_t header_len = OpenVPNPacketOpcodeLength + OpenVPNPacketSessionIdLength + OpenVPNPacketReplayIdLength + OpenVPNPacketReplayTimestampLength;
    return header_len + enc_capacity;
}

size_t openvpn_ctrl_serialize(uint8_t *_Nonnull dst, const openvpn_ctrl *_Nonnull pkt) {
    uint8_t *ptr = dst;
    if (pkt->ack_ids) {
        *ptr = pkt->ack_ids_len;
        ptr += OpenVPNPacketAckLengthLength;
        for (size_t i = 0; i < pkt->ack_ids_len; ++i) {
            const uint32_t ack_id = pkt->ack_ids[i];
            *(uint32_t *)ptr = pp_endian_htonl(ack_id);
            ptr += OpenVPNPacketIdLength;
        }
        pp_assert(pkt->ack_remote_session_id);
        memcpy(ptr, pkt->ack_remote_session_id, OpenVPNPacketSessionIdLength);
        ptr += OpenVPNPacketSessionIdLength;
    } else {
        *ptr = 0; // no acks
        ptr += OpenVPNPacketAckLengthLength;
    }
    if (pkt->code != OpenVPNPacketCodeAckV1) {
        *(uint32_t *)ptr = pp_endian_htonl(pkt->packet_id);
        ptr += OpenVPNPacketIdLength;
        if (pkt->payload) {
            memcpy(ptr, pkt->payload, pkt->payload_len);
            ptr += pkt->payload_len;
        }
    }
    return ptr - dst;
}

// MARK: - Auth

size_t openvpn_ctrl_serialize_auth(uint8_t *dst,
                               size_t dst_buf_len,
                               const openvpn_ctrl *pkt,
                               openvpn_ctrl_alg *alg,
                               pp_crypto_error_code *error) {

    const size_t digest_len = alg->crypto->base.meta.digest_len;
    uint8_t *ptr = dst + digest_len;
    const uint8_t *subject = ptr;
    *(uint32_t *)ptr = pp_endian_htonl(alg->replay_id);
    ptr += OpenVPNPacketReplayIdLength;
    *(uint32_t *)ptr = pp_endian_htonl(alg->timestamp);
    ptr += OpenVPNPacketReplayTimestampLength;
    ptr += openvpn_packet_header_set(ptr, pkt->code, pkt->key, pkt->session_id);
    ptr += openvpn_ctrl_serialize(ptr, pkt);

    const size_t subject_len = ptr - subject;
    const size_t dst_len = pp_crypto_encrypt(alg->crypto,
                                          dst,
                                          dst_buf_len,
                                          subject,
                                          subject_len,
                                          NULL,
                                          error);
    if (!dst_len) {
        return 0;
    }
    pp_assert(dst_len == digest_len + subject_len);//, @"Encrypted packet size != (Digest + Subject)");
    openvpn_data_swap(dst, digest_len + OpenVPNPacketReplayIdLength + OpenVPNPacketReplayTimestampLength, OpenVPNPacketOpcodeLength + OpenVPNPacketSessionIdLength);
    return dst_len;
}

// MARK: - Crypt

size_t openvpn_ctrl_serialize_crypt(uint8_t *dst,
                                size_t dst_buf_len,
                                const openvpn_ctrl *pkt,
                                openvpn_ctrl_alg *alg,
                                pp_crypto_error_code *error) {

    uint8_t *ptr = dst;
    ptr += openvpn_packet_header_set(dst, pkt->code, pkt->key, pkt->session_id);
    *(uint32_t *)ptr = pp_endian_htonl(alg->replay_id);
    ptr += OpenVPNPacketReplayIdLength;
    *(uint32_t *)ptr = pp_endian_htonl(alg->timestamp);
    ptr += OpenVPNPacketReplayTimestampLength;

    const size_t ad_len = ptr - dst;
    const pp_crypto_flags flags = { NULL, 0, dst, ad_len, false };

    const size_t raw_capacity = openvpn_ctrl_raw_capacity(pkt);
    pp_zd *msg = pp_zd_create(raw_capacity);
    openvpn_ctrl_serialize(msg->bytes, pkt);
    const size_t enc_msg_len = pp_crypto_encrypt(alg->crypto,
                                              dst + ad_len,
                                              dst_buf_len - ad_len,
                                              msg->bytes,
                                              msg->length,
                                              &flags,
                                              error);
    if (!enc_msg_len) {
        pp_zd_free(msg);
        return 0;
    }
    pp_zd_free(msg);
    return ad_len + enc_msg_len;
}
