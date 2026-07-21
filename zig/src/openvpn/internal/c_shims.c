/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

/*
 * Keep this operation in C. Zig's translate-c cannot lower the existing
 * static-inline implementation because it contains control flow over C
 * bitfield types, so expose that implementation through a stable ABI call.
 */

#include "openvpn/openvpn.h"

pp_zd *partout_openvpn_dp_mode_decrypt_and_parse(
    openvpn_dp_mode *mode,
    pp_zd *buf,
    uint32_t *dst_packet_id,
    uint8_t *dst_header,
    bool *dst_keep_alive,
    const uint8_t *src,
    size_t src_len,
    openvpn_dp_error *error
) {
    return openvpn_dp_mode_decrypt_and_parse(
        mode,
        buf,
        dst_packet_id,
        dst_header,
        dst_keep_alive,
        src,
        src_len,
        error
    );
}

pp_zd *partout_openvpn_pkt_proc_stream_recv(
    const openvpn_pkt_proc *processor,
    const uint8_t *source,
    size_t source_length,
    size_t *source_received
) {
    return openvpn_pkt_proc_stream_recv(
        processor,
        source,
        source_length,
        source_received
    );
}

size_t partout_openvpn_pkt_proc_stream_send(
    const openvpn_pkt_proc *processor,
    pp_zd *destination,
    size_t destination_offset,
    const uint8_t *source,
    size_t source_length
) {
    return openvpn_pkt_proc_stream_send(
        processor,
        destination,
        destination_offset,
        source,
        source_length
    );
}
