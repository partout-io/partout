/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <errno.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <arpa/inet.h>
#include <netdb.h>

/* POSIX systems use int for both I/O and watching.  */
struct __pp_socket_struct {
    pp_socket_fd fd;
};

typedef socklen_t os_socklen_t;

static inline void local_print_error(const char *msg) {
    pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "%s failed: %s", msg, strerror(errno));
}

static inline bool local_platform_init(void) {
    return true;
}

static inline pp_socket_fd local_invalid_fd(void) {
    return -1;
}

static inline pp_fd local_invalid_watch_fd(void) {
    return -1;
}

static inline pp_fd local_socket_watch_fd(const pp_socket sock) {
    return sock->fd;
}

static inline void local_set_not_socket_error(void) {
    errno = EBADF;
}

static inline void local_set_timeout_error(void) {
    errno = ETIMEDOUT;
}

static inline void local_set_reset_error(void) {
    errno = EPIPE;
}

static inline void local_set_error(int err) {
    errno = err;
}

static inline bool local_is_connect_pending(void) {
    return errno == EINPROGRESS;
}

static inline int local_close_fd(pp_socket_fd fd) {
    return close(fd);
}

static inline int local_shutdown_fd(pp_socket_fd fd) {
    return shutdown(fd, SHUT_RDWR);
}

static inline int local_recv_fd(pp_socket_fd fd, void *dst, size_t dst_len) {
    return (int)read(fd, dst, dst_len);
}

static inline int local_send_fd(pp_socket_fd fd, const void *src, size_t src_len) {
    return (int)write(fd, src, src_len);
}

static inline int local_select_nfds(pp_socket_fd fd) {
    return fd + 1;
}

static inline bool local_init_socket(pp_socket sock) {
    (void)sock;
    return true;
}

static inline void local_cleanup_socket(pp_socket sock) {
    (void)sock;
}

static inline bool local_is_interrupted(void) {
    return errno == EINTR;
}

static inline bool local_is_wouldblock(void) {
    return errno == EAGAIN || errno == EWOULDBLOCK;
}

static inline bool local_is_nobufs(void) {
    return errno == ENOBUFS;
}

// pp_socket_fd == pp_fd in POSIX

int pp_socket_set_nonblocking(pp_socket_fd fd, int *original_flags) {
    const int ret = pp_fd_set_nonblocking(fd, original_flags);
    if (ret < 0) {
        local_print_error("pp_fd_set_nonblocking()");
    }
    return ret;
}

int pp_socket_restore_blocking(pp_socket_fd fd, int original_flags) {
    const int ret = pp_fd_restore_blocking(fd, original_flags);
    if (ret < 0) {
        local_print_error("pp_socket_restore_blocking()");
    }
    return ret;
}

bool pp_socket_set_event_mask(pp_socket sock, bool read, bool write) {
    if (!local_is_valid_socket(sock)) {
        local_set_not_socket_error();
        return false;
    }
    (void)read;
    (void)write;
    return true;
}

bool pp_socket_reset_events(pp_socket sock) {
    if (!local_is_valid_socket(sock)) {
        local_set_not_socket_error();
        return false;
    }
    return true;
}
