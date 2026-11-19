/* SPDX-FileCopyrightText: 2026 Davide De Rosa
 * SPDX-License-Identifier: GPL-3.0 */
#include "portable/common.h"
#include "portable/tun.h"
#include "portable/tun_wintun.h"

void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    if (tun->session) tun->end_session(tun->session);
    if (tun->adapter) tun->close_adapter(tun->adapter);
    FreeLibrary(tun->library);
    pp_free(tun);
}

int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len) {
    if (!tun || !tun->session) {
        SetLastError(ERROR_INVALID_HANDLE);
        return -1;
    }
    if (!dst || dst_len == 0) return -1;
    DWORD packet_len;
    BYTE *packet = tun->receive_packet(tun->session, &packet_len);
    if (!packet) {
        const DWORD err = GetLastError();
        if (err == ERROR_NO_MORE_ITEMS) {
            return PPIOErrorWouldBlock;
        }
        pp_clog_v(PPLogLevelFault, "tun_windows: read(), %lu", err);
        return -1;
    }
    if (dst_len < packet_len) {
        tun->release_receive_packet(tun->session, packet);
        SetLastError(ERROR_INSUFFICIENT_BUFFER);
        return -1;
    }
    memcpy(dst, packet, packet_len);
    tun->release_receive_packet(tun->session, packet);
    return (int)packet_len;
}

int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len) {
    if (!tun || !tun->session) {
        SetLastError(ERROR_INVALID_HANDLE);
        return -1;
    }
    if (!src || src_len == 0) return -1;
    BYTE *packet = tun->allocate_send_packet(tun->session, src_len);
    if (!packet) {
        const DWORD err = GetLastError();
        if (err == ERROR_BUFFER_OVERFLOW) {
            return PPIOErrorNoBufs;
        }
        pp_clog_v(PPLogLevelFault, "tun_windows: write(), %lu", err);
        return -1;
    }
    memcpy(packet, src, src_len);
    tun->send_packet(tun->session, packet);
    return (int)src_len;
}

pp_fd pp_tun_get_watch_fd(const pp_tun tun) {
    if (!tun || !tun->session) return INVALID_HANDLE_VALUE;
    return tun->get_read_wait_event(tun->session);
}
