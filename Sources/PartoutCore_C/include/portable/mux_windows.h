/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/mux.h"

struct pp_mux_entry {
    pp_fd fd;
    bool read;
    bool write;
};

struct __pp_mux {
    struct pp_mux_entry *entries;
    int entries_len;
    pp_fd wake_event;
    pp_fd *handles;
    int num_tracked;
    void (*on_readable)(void *ctx, pp_fd fd);
    void (*on_writable)(void *ctx, pp_fd fd);
    void *read_ctx;
    void *write_ctx;
};

static bool pp_mux_is_valid_handle(pp_fd fd) {
    return fd && fd != INVALID_HANDLE_VALUE;
}

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
    if (mux->num_tracked >= mux->entries_len) {
        pp_clog_v(PPLogLevelFault, "Too many tracked fds");
        return NULL;
    }
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

static bool pp_mux_is_enabled(const struct pp_mux_entry *entry) {
    return entry->read || entry->write;
}

static int pp_mux_build_handles(pp_mux mux) {
    int count = 0;
    mux->handles[count] = mux->wake_event;
    ++count;

    for (int i = 0; i < mux->num_tracked; ++i) {
        const struct pp_mux_entry *tracked = mux->entries + i;
        if (!pp_mux_is_enabled(tracked)) continue;
        mux->handles[count] = tracked->fd;
        ++count;
    }
    return count;
}

pp_mux pp_mux_create(int num) {
    if (num <= 0) return NULL;
    /* Adds 1 to account for wake_event. */
    if (num > MAXIMUM_WAIT_OBJECTS - 1) return NULL;

    pp_fd wake_event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!wake_event) return NULL;

    pp_mux mux = pp_alloc(sizeof(*mux));
    mux->entries = pp_alloc(num * sizeof(struct pp_mux_entry));
    mux->entries_len = num;
    mux->wake_event = wake_event;
    mux->handles = pp_alloc((1 + num) * sizeof(pp_fd));

    return mux;
}

void pp_mux_free(pp_mux mux) {
    if (!mux) return;
    CloseHandle(mux->wake_event);
    pp_free(mux->handles);
    pp_free(mux->entries);
    pp_free(mux);
}

bool pp_mux_add(pp_mux mux, pp_fd fd) {
    if (!mux || !pp_mux_is_valid_handle(fd)) return false;
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

int pp_mux_wait_timeout(pp_mux mux, int *error_code, int timeout_ms) {
    if (!mux) return PPMuxErrorNull;

    const int handles_count = pp_mux_build_handles(mux);
    const DWORD timeout = timeout_ms < 0 ? INFINITE : (DWORD)timeout_ms;
    const DWORD ret = WaitForMultipleObjects((DWORD)handles_count, mux->handles, FALSE, timeout);
    if (ret == WAIT_TIMEOUT) {
        return 0;
    }
    if (ret == WAIT_FAILED) {
        const DWORD error = GetLastError();
        pp_clog_v(PPLogLevelFault, "pp_mux_wait_timeout WaitForMultipleObjects() failed: error=%lu", error);
        if (error_code) *error_code = (int)error;
        return -1;
    }

    const DWORD first = WAIT_OBJECT_0;
    const DWORD last = WAIT_OBJECT_0 + (DWORD)handles_count;
    if (ret < first || ret >= last) {
        pp_clog_v(PPLogLevelFault, "pp_mux_wait_timeout WaitForMultipleObjects() unexpected status: %lu", ret);
        if (error_code) *error_code = (int)ret;
        return -1;
    }

    const int index = (int)(ret - WAIT_OBJECT_0);
    const pp_fd fd = mux->handles[index];
    if (fd == mux->wake_event) {
        return 1;
    }

    const struct pp_mux_entry *tracked = pp_mux_entry_find(mux, fd);
    if (!tracked) return 1;
    if (tracked->read && mux->on_readable) {
        mux->on_readable(mux->read_ctx, fd);
    }
    if (tracked->write && mux->on_writable) {
        mux->on_writable(mux->write_ctx, fd);
    }
    return 1;
}

int pp_mux_wait(pp_mux mux, int *error_code) {
    return pp_mux_wait_timeout(mux, error_code, -1);
}

bool pp_mux_wake(pp_mux mux) {
    if (!mux) return false;
    return SetEvent(mux->wake_event);
}
