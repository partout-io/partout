/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/mux.h"
#include <errno.h>

const int PPMuxErrorNull = -2;

#if PARTOUT_APPLE
#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <unistd.h>

#define PP_MUX_WAKE_ID 1

struct __pp_mux {
    int handle;
    struct kevent *events;
    int events_len;
    void (*on_readable)(void *ctx, int fd);
    void (*on_writable)(void *ctx, int fd);
    void *read_ctx;
    void *write_ctx;
};

pp_mux pp_mux_create(int num) {
    int handle = kqueue();
    if (handle < 0) return NULL;
    pp_mux mux = pp_alloc(sizeof(*mux));
    mux->handle = handle;
    const int max_events = 1 + 2 * num;
    mux->events = pp_alloc(max_events * sizeof(struct kevent));
    mux->events_len = max_events;

    /* EV_CLEAR resets the fd after wake delivery. */
    struct kevent ev;
    EV_SET(&ev, PP_MUX_WAKE_ID, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
    int ret;
    PP_IO_RETRY(ret, kevent(mux->handle, &ev, 1, NULL, 0, NULL));
    if (ret != 0) {
        pp_mux_free(mux);
        return NULL;
    }
    return mux;
}

void pp_mux_free(pp_mux mux) {
    if (!mux) return;
    close(mux->handle);
    pp_free(mux->events);
    pp_free(mux);
}

bool pp_mux_add(pp_mux mux, int fd) {
    if (!mux) return false;
    struct kevent ev;
    EV_SET(&ev, fd, EVFILT_READ, EV_ADD, 0, 0, 0);
    int ret;
    PP_IO_RETRY(ret, kevent(mux->handle, &ev, 1, NULL, 0, NULL));
    return ret == 0;
}

bool pp_mux_delete(pp_mux mux, int fd) {
    if (!mux) return false;
    struct kevent ev[2];
    EV_SET(&ev[0], fd, EVFILT_READ, EV_DELETE, 0, 0, 0);
    EV_SET(&ev[1], fd, EVFILT_WRITE, EV_DELETE, 0, 0, 0);

    bool ok = true;
    for (int i = 0; i < 2; ++i) {
        int ret;
        PP_IO_RETRY(ret, kevent(mux->handle, &ev[i], 1, NULL, 0, NULL));
        if (ret < 0 && errno != ENOENT) {
            ok = false;
        }
    }
    return ok;
}

bool pp_mux_set_read(pp_mux mux, int fd, bool enable) {
    if (!mux) return false;
    struct kevent ev;
    EV_SET(&ev, fd, EVFILT_READ, enable ? EV_ADD : EV_DELETE, 0, 0, 0);
    int ret;
    PP_IO_RETRY(ret, kevent(mux->handle, &ev, 1, NULL, 0, NULL));
    if (ret < 0) {
        /* Ignore failed deletion. */
        if (!enable && errno == ENOENT) return true;
        return false;
    }
    return true;
}

bool pp_mux_set_write(pp_mux mux, int fd, bool enable) {
    if (!mux) return false;
    struct kevent ev;
    EV_SET(&ev, fd, EVFILT_WRITE, enable ? EV_ADD : EV_DELETE, 0, 0, 0);
    int ret;
    PP_IO_RETRY(ret, kevent(mux->handle, &ev, 1, NULL, 0, NULL));
    if (ret < 0) {
        /* Ignore failed deletion. */
        if (!enable && errno == ENOENT) return true;
        return false;
    }
    return true;
}

void pp_mux_set_on_readable(pp_mux mux, void (*callback)(void *ctx, int fd), void *ctx) {
    if (!mux) return;
    mux->on_readable = callback;
    mux->read_ctx = ctx;
}

void pp_mux_set_on_writable(pp_mux mux, void (*callback)(void *ctx, int fd), void *ctx) {
    if (!mux) return;
    mux->on_writable = callback;
    mux->write_ctx = ctx;
}

int pp_mux_wait(pp_mux mux, int *error_code) {
    if (!mux) return PPMuxErrorNull;

    int num;
    PP_IO_RETRY(num, kevent(mux->handle, NULL, 0, mux->events, mux->events_len, NULL));
    if (num < 0) {
        pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "pp_mux_wait kevent() failed: errno=%d", errno);
        if (error_code) *error_code = errno;
        return num;
    }

    for (int i = 0; i < num; ++i) {
        const struct kevent *ev = mux->events + i;
        const int fd = (int)ev->ident;
        if (ev->filter == EVFILT_READ) {
            if (mux->on_readable) {
                mux->on_readable(mux->read_ctx, fd);
            }
        } else if (ev->filter == EVFILT_WRITE) {
            if (mux->on_writable) {
                mux->on_writable(mux->write_ctx, fd);
            }
        } else if (ev->filter == EVFILT_USER && ev->ident == PP_MUX_WAKE_ID) {
            continue;
        }
    }
    return num;
}

bool pp_mux_wake(pp_mux mux) {
    if (!mux) return false;
    struct kevent ev;
    EV_SET(&ev, PP_MUX_WAKE_ID, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    int ret;
    PP_IO_RETRY(ret, kevent(mux->handle, &ev, 1, NULL, 0, NULL));
    return ret == 0;
}

#elif PARTOUT_LINUX || PARTOUT_ANDROID
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <stdint.h>
#include <unistd.h>

#ifndef EPOLLRDHUP
#define EPOLLRDHUP 0
#endif

#define PP_MUX_ERROR_EVENTS (EPOLLERR | EPOLLHUP | EPOLLRDHUP)

struct pp_mux_fd {
    int fd;
    bool read;
    bool write;
    bool registered;
};

struct __pp_mux {
    int handle;
    int wake_fd;
    struct epoll_event *events;
    int events_len;
    struct pp_mux_fd *fds;
    int fds_len;
    int fds_count;
    void (*on_readable)(void *ctx, int fd);
    void (*on_writable)(void *ctx, int fd);
    void *read_ctx;
    void *write_ctx;
};

static struct pp_mux_fd *pp_mux_find_fd(pp_mux mux, int fd) {
    for (int i = 0; i < mux->fds_count; ++i) {
        if (mux->fds[i].fd == fd) return mux->fds + i;
    }
    return NULL;
}

static struct pp_mux_fd *pp_mux_track_fd(pp_mux mux, int fd) {
    struct pp_mux_fd *tracked = pp_mux_find_fd(mux, fd);
    if (tracked) return tracked;
    if (mux->fds_count >= mux->fds_len) return NULL;
    tracked = mux->fds + mux->fds_count;
    tracked->fd = fd;
    tracked->read = false;
    tracked->write = false;
    tracked->registered = false;
    ++mux->fds_count;
    return tracked;
}

static void pp_mux_untrack_fd(pp_mux mux, struct pp_mux_fd *fd) {
    const int index = (int)(fd - mux->fds);
    --mux->fds_count;
    if (index != mux->fds_count) {
        mux->fds[index] = mux->fds[mux->fds_count];
    }
}

static uint32_t pp_mux_events(const struct pp_mux_fd *fd) {
    uint32_t events = 0;
    if (fd->read || fd->write) events |= PP_MUX_ERROR_EVENTS;
    if (fd->read) events |= EPOLLIN;
    if (fd->write) events |= EPOLLOUT;
    return events;
}

static bool pp_mux_sync_fd(pp_mux mux, struct pp_mux_fd *fd) {
    const uint32_t events = pp_mux_events(fd);
    if (events == 0) {
        if (!fd->registered) return true;
        const int ret = epoll_ctl(mux->handle, EPOLL_CTL_DEL, fd->fd, NULL);
        if (ret != 0 && errno != ENOENT) return false;
        fd->registered = false;
        return true;
    }

    struct epoll_event ev;
    pp_zero(&ev, sizeof(ev));
    ev.events = events;
    ev.data.fd = fd->fd;

    if (fd->registered) {
        const int ret = epoll_ctl(mux->handle, EPOLL_CTL_MOD, fd->fd, &ev);
        if (ret == 0) return true;
        if (errno != ENOENT) return false;
        fd->registered = false;
    }

    const int ret = epoll_ctl(mux->handle, EPOLL_CTL_ADD, fd->fd, &ev);
    if (ret == 0) {
        fd->registered = true;
        return true;
    }
    if (errno == EEXIST) {
        fd->registered = true;
        if (epoll_ctl(mux->handle, EPOLL_CTL_MOD, fd->fd, &ev) == 0) {
            return true;
        }
    }
    return false;
}

pp_mux pp_mux_create(int num) {
    int handle = epoll_create(1); /* Size is ignored */
    if (handle < 0) return NULL;
    int wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (wake_fd < 0) {
        close(handle);
        return NULL;
    }

    pp_mux mux = pp_alloc(sizeof(*mux));
    mux->handle = handle;
    mux->wake_fd = wake_fd;
    mux->events = pp_alloc((1 + num) * sizeof(struct epoll_event));
    mux->events_len = 1 + num;
    mux->fds = pp_alloc(num * sizeof(struct pp_mux_fd));
    mux->fds_len = num;

    struct epoll_event ev;
    pp_zero(&ev, sizeof(ev));
    ev.events = EPOLLIN;
    ev.data.fd = mux->wake_fd;
    if (epoll_ctl(mux->handle, EPOLL_CTL_ADD, mux->wake_fd, &ev) != 0) {
        pp_mux_free(mux);
        return NULL;
    }

    return mux;
}

void pp_mux_free(pp_mux mux) {
    if (!mux) return;
    close(mux->handle);
    close(mux->wake_fd);
    pp_free(mux->events);
    pp_free(mux->fds);
    pp_free(mux);
}

bool pp_mux_add(pp_mux mux, int fd) {
    if (!mux) return false;
    const int previous_count = mux->fds_count;
    struct pp_mux_fd *tracked = pp_mux_track_fd(mux, fd);
    if (!tracked) return false;
    const bool previous_read = tracked->read;
    const bool previous_write = tracked->write;
    tracked->read = true;
    tracked->write = false;
    const bool ok = pp_mux_sync_fd(mux, tracked);
    if (!ok) {
        tracked->read = previous_read;
        tracked->write = previous_write;
        pp_mux_sync_fd(mux, tracked);
        mux->fds_count = previous_count;
        return false;
    }
    return true;
}

bool pp_mux_delete(pp_mux mux, int fd) {
    if (!mux) return false;
    struct pp_mux_fd *tracked = pp_mux_find_fd(mux, fd);
    if (!tracked) return true;

    if (tracked->registered) {
        const int ret = epoll_ctl(mux->handle, EPOLL_CTL_DEL, fd, NULL);
        if (ret != 0 && errno != ENOENT) {
            return false;
        }
        tracked->registered = false;
    }
    pp_mux_untrack_fd(mux, tracked);
    return true;
}

bool pp_mux_set_read(pp_mux mux, int fd, bool enable) {
    if (!mux) return false;
    struct pp_mux_fd *tracked = pp_mux_find_fd(mux, fd);
    if (!tracked && !enable) return true;
    if (!tracked) return false;

    const bool previous_read = tracked->read;
    tracked->read = enable;
    const bool ok = pp_mux_sync_fd(mux, tracked);
    if (!ok) {
        tracked->read = previous_read;
        pp_mux_sync_fd(mux, tracked);
        return false;
    }
    return true;
}

bool pp_mux_set_write(pp_mux mux, int fd, bool enable) {
    if (!mux) return false;
    struct pp_mux_fd *tracked = pp_mux_find_fd(mux, fd);
    if (!tracked && !enable) return true;
    if (!tracked) return false;

    const bool previous_write = tracked->write;
    tracked->write = enable;
    const bool ok = pp_mux_sync_fd(mux, tracked);
    if (!ok) {
        tracked->write = previous_write;
        pp_mux_sync_fd(mux, tracked);
        return false;
    }
    return true;
}

void pp_mux_set_on_readable(pp_mux mux, void (*callback)(void *ctx, int fd), void *ctx) {
    if (!mux) return;
    mux->on_readable = callback;
    mux->read_ctx = ctx;
}

void pp_mux_set_on_writable(pp_mux mux, void (*callback)(void *ctx, int fd), void *ctx) {
    if (!mux) return;
    mux->on_writable = callback;
    mux->write_ctx = ctx;
}

int pp_mux_wait(pp_mux mux, int *error_code) {
    if (!mux) return PPMuxErrorNull;

    int num;
    PP_IO_RETRY(num, epoll_wait(mux->handle, mux->events, mux->events_len, -1));
    if (num < 0) {
        pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "pp_mux_wait epoll_wait() failed: errno=%d", errno);
        if (error_code) *error_code = errno;
        return num;
    }

    for (int i = 0; i < num; ++i) {
        const struct epoll_event *ev = mux->events + i;
        const int fd = ev->data.fd;
        if (fd == mux->wake_fd) {
            eventfd_t value;
            while (true) {
                int ret;
                /* Context: wake_fd is non-blocking */
                PP_IO_RETRY(ret, eventfd_read(mux->wake_fd, &value));
                if (ret < 0) {
                    /* Fully drained */
                    if (PP_IO_WOULDBLOCK()) break;
                    /* Unexpected error */
                    pp_clog_v(PPLogCategoryCore, PPLogLevelFault, "pp_mux_wait eventfd_read() failed: errno=%d", errno);
                    return ret;
                }
            }
            continue;
        }
        const struct pp_mux_fd *tracked = pp_mux_find_fd(mux, fd);
        if (!tracked) continue;
        const bool failed = ev->events & PP_MUX_ERROR_EVENTS;
        const bool readable = tracked->read && ((ev->events & EPOLLIN) || failed);
        const bool writable = tracked->write && ((ev->events & EPOLLOUT) || failed);
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
    int ret;
    PP_IO_RETRY(ret, eventfd_write(mux->wake_fd, 1));
    if (ret == 0) return true;
    return errno == EAGAIN;
}
#endif
