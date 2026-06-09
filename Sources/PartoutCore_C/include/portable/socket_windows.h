/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

static inline bool local_platform_init(void) {
    static int wsa_initialized = 0;
    if (!wsa_initialized) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            local_print_error("WSAStartup()");
            return false;
        }
        wsa_initialized = 1;
    }
    return true;
}

static inline void local_print_error(const char *msg) {
    pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "%s failed with error %d", msg, WSAGetLastError());
}

static inline pp_socket_fd local_invalid_fd(void) {
    return INVALID_SOCKET;
}

static inline bool local_is_invalid_fd(pp_socket_fd fd) {
    return fd == INVALID_SOCKET;
}

static inline void local_set_not_socket_error(void) {
    WSASetLastError(WSAENOTSOCK);
}

static inline void local_set_timeout_error(void) {
    WSASetLastError(WSAETIMEDOUT);
}

static inline void local_set_reset_error(void) {
    WSASetLastError(WSAECONNRESET);
}

static inline void local_set_error(int err) {
    WSASetLastError(err);
}

static inline bool local_is_connect_pending(void) {
    const int err = WSAGetLastError();
    return err == WSAEWOULDBLOCK || err == WSAEINPROGRESS;
}

static inline int local_close_fd(pp_socket_fd fd) {
    return closesocket(fd);
}

static inline int local_shutdown_fd(pp_socket_fd fd) {
    return shutdown(fd, SD_BOTH);
}

static inline int local_recv_fd(pp_socket_fd fd, void *dst, size_t dst_len) {
    return (int)recv(fd, dst, (int)dst_len, 0);
}

static inline int local_send_fd(pp_socket_fd fd, const void *src, size_t src_len) {
    return (int)send(fd, src, (int)src_len, 0);
}

static inline int local_select_nfds(pp_socket_fd fd) {
    (void)fd;
    return 0;
}

static inline bool local_is_interrupted(void) {
    return WSAGetLastError() == WSAEINTR;
}

static inline bool local_is_wouldblock(void) {
    return WSAGetLastError() == WSAEWOULDBLOCK;
}

static inline bool local_is_nobufs(void) {
    return WSAGetLastError() == WSAENOBUFS;
}

int pp_socket_set_nonblocking(pp_socket_fd fd, int *original_flags) {
    (void)original_flags;
    u_long mode = 1;
    if (ioctlsocket(fd, FIONBIO, &mode) == SOCKET_ERROR) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "ioctlsocket(): set");
        return -1;
    }
    return 0;
}

int pp_socket_restore_blocking(pp_socket_fd fd, int original_flags) {
    (void)original_flags;
    u_long mode = 0;
    if (ioctlsocket(fd, FIONBIO, &mode) == SOCKET_ERROR) {
        pp_clog(PPLogCategoryCore, PPLogLevelFault, "ioctlsocket(): restore");
        return -1;
    }
    return 0;
}
