/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/mux.h"
#include <errno.h>

const int PPMuxErrorNull = -2;

#if PARTOUT_WINDOWS
// FIXME: ###, Implement mux.c on Windows
#else
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <unistd.h>

#define PP_MUX_ERROR_EVENTS (POLLERR | POLLHUP | POLLNVAL)

struct pp_mux_entry {
    pp_fd fd;
    bool read;
    bool write;
};

struct __pp_mux {
    struct pp_mux_entry *entries;
    int entries_len;
    pp_fd wake_pipe[2];
    struct pollfd *pollfds;
    int num_tracked;
    void (*on_readable)(void *ctx, pp_fd fd);
    void (*on_writable)(void *ctx, pp_fd fd);
    void *read_ctx;
    void *write_ctx;
};

static struct pp_mux_entry *pp_mux_entry_find(pp_mux mux, pp_fd fd) {
    for (int i = 0; i < mux->num_tracked; ++i) {
        if (mux->entries[i].fd == fd) return mux->entries + i;
    }
    return NULL;
}

static struct pp_mux_entry *pp_mux_track_fd(pp_mux mux, pp_fd fd) {
    struct pp_mux_entry *tracked = pp_mux_entry_find(mux, fd);
    if (tracked) return tracked;
    /* Do not track more than fds_len. */
    if (mux->num_tracked >= mux->entries_len) return NULL;
    tracked = mux->entries + mux->num_tracked;
    tracked->fd = fd;
    tracked->read = false;
    tracked->write = false;
    ++mux->num_tracked;
    return tracked;
}

static void pp_mux_untrack_fd(pp_mux mux, struct pp_mux_entry *entry) {
    const int index = (int)(entry - mux->entries);
    --mux->num_tracked;
    if (index != mux->num_tracked) {
        mux->entries[index] = mux->entries[mux->num_tracked];
    }
}

static short pp_mux_events(const struct pp_mux_entry *entry) {
    short events = 0;
    if (entry->read) events |= POLLIN;
    if (entry->write) events |= POLLOUT;
    return events;
}

static int pp_mux_build_pollfds(pp_mux mux) {
    int count = 0;
    mux->pollfds[count].fd = mux->wake_pipe[0];
    mux->pollfds[count].events = POLLIN;
    mux->pollfds[count].revents = 0;
    ++count;

    for (int i = 0; i < mux->num_tracked; ++i) {
        const struct pp_mux_entry *tracked = mux->entries + i;
        const short events = pp_mux_events(tracked);
        if (events == 0) continue;
        mux->pollfds[count].fd = tracked->fd;
        mux->pollfds[count].events = events;
        mux->pollfds[count].revents = 0;
        ++count;
    }
    return count;
}

static bool pp_mux_set_cloexec(pp_fd fd) {
    const int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0) return false;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;
}

static int pp_mux_drain_wake(pp_mux mux) {
    uint8_t buffer[64];
    while (true) {
        ssize_t ret;
        /* Context: wake_pipe[0] is non-blocking. */
        PP_IO_RETRY(ret, read(mux->wake_pipe[0], buffer, sizeof(buffer)));
        if (ret < 0) {
            if (pp_io_wouldblock()) return 0;
            pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "pp_mux_wait wake read() failed: errno=%d", errno);
            return (int)ret;
        }
        if (ret == 0) return 0;
    }
}

pp_mux pp_mux_create(int num) {
    if (num <= 0) return NULL;
    pp_fd wake_pipe[2];
    if (pipe(wake_pipe) != 0) return NULL;
    if (!pp_mux_set_cloexec(wake_pipe[0]) ||
        !pp_mux_set_cloexec(wake_pipe[1]) ||
        pp_fd_set_nonblocking(wake_pipe[0], NULL) != 0 ||
        pp_fd_set_nonblocking(wake_pipe[1], NULL) != 0) {
        close(wake_pipe[0]);
        close(wake_pipe[1]);
        return NULL;
    }

    pp_mux mux = pp_alloc(sizeof(*mux));
    mux->entries = pp_alloc(num * sizeof(struct pp_mux_entry));
    mux->entries_len = num;
    mux->wake_pipe[0] = wake_pipe[0];
    mux->wake_pipe[1] = wake_pipe[1];
    /* Adds 1 to account for wake_pipe. */
    mux->pollfds = pp_alloc((1 + num) * sizeof(struct pollfd));

    return mux;
}

void pp_mux_free(pp_mux mux) {
    if (!mux) return;
    close(mux->wake_pipe[1]);
    close(mux->wake_pipe[0]);
    pp_free(mux->pollfds);
    pp_free(mux->entries);
    pp_free(mux);
}

bool pp_mux_add(pp_mux mux, pp_fd fd) {
    if (!mux) return false;
    struct pp_mux_entry *tracked = pp_mux_track_fd(mux, fd);
    if (!tracked) return false;
    tracked->read = true;
    tracked->write = false;
    return true;
}

bool pp_mux_delete(pp_mux mux, pp_fd fd) {
    if (!mux) return false;
    struct pp_mux_entry *tracked = pp_mux_entry_find(mux, fd);
    if (!tracked) return true;
    pp_mux_untrack_fd(mux, tracked);
    return true;
}

bool pp_mux_set_read(pp_mux mux, pp_fd fd, bool enable) {
    if (!mux) return false;
    struct pp_mux_entry *tracked = pp_mux_entry_find(mux, fd);
    if (!tracked && !enable) return true;
    if (!tracked) return false;
    tracked->read = enable;
    return true;
}

bool pp_mux_set_write(pp_mux mux, pp_fd fd, bool enable) {
    if (!mux) return false;
    struct pp_mux_entry *tracked = pp_mux_entry_find(mux, fd);
    if (!tracked && !enable) return true;
    if (!tracked) return false;
    tracked->write = enable;
    return true;
}

void pp_mux_set_on_readable(pp_mux mux, void (*callback)(void *ctx, pp_fd fd), void *ctx) {
    if (!mux) return;
    mux->on_readable = callback;
    mux->read_ctx = ctx;
}

void pp_mux_set_on_writable(pp_mux mux, void (*callback)(void *ctx, pp_fd fd), void *ctx) {
    if (!mux) return;
    mux->on_writable = callback;
    mux->write_ctx = ctx;
}

int pp_mux_wait(pp_mux mux, int *error_code) {
    if (!mux) return PPMuxErrorNull;

    const int pollfds_count = pp_mux_build_pollfds(mux);
    int num;
    PP_IO_RETRY(num, poll(mux->pollfds, (nfds_t)pollfds_count, -1));
    if (num < 0) {
        pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "pp_mux_wait poll() failed: errno=%d", errno);
        if (error_code) *error_code = errno;
        return num;
    }

    for (int i = 0; i < pollfds_count; ++i) {
        const struct pollfd *pollfd = mux->pollfds + i;
        const short revents = pollfd->revents;
        if (revents == 0) continue;
        const pp_fd fd = pollfd->fd;
        if (fd == mux->wake_pipe[0]) {
            const int ret = pp_mux_drain_wake(mux);
            if (ret < 0) {
                if (error_code) *error_code = errno;
                return ret;
            }
            continue;
        }
        const struct pp_mux_entry *tracked = pp_mux_entry_find(mux, fd);
        if (!tracked) continue;
        const bool failed = revents & PP_MUX_ERROR_EVENTS;
        const bool readable = tracked->read && ((revents & POLLIN) || failed);
        const bool writable = tracked->write && ((revents & POLLOUT) || failed);
        if (readable && mux->on_readable) {
            mux->on_readable(mux->read_ctx, fd);
        }
        if (writable && mux->on_writable) {
            mux->on_writable(mux->write_ctx, fd);
        }
    }
    return num;
}

bool pp_mux_wake(pp_mux mux) {
    if (!mux) return false;
    const uint8_t byte = 1;
    ssize_t ret;
    PP_IO_RETRY(ret, write(mux->wake_pipe[1], &byte, sizeof(byte)));
    if (ret == (ssize_t)sizeof(byte)) return true;
    return pp_io_wouldblock();
}
#endif
