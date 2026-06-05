/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/mux.h"
#include <errno.h>

#define PP_MUX_WAKE_ID 1

#if PARTOUT_APPLE
#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <unistd.h>

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
    if (kevent(mux->handle, &ev, 1, NULL, 0, NULL) != 0) {
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
    return kevent(mux->handle, &ev, 1, NULL, 0, NULL) == 0;
}

bool pp_mux_set_write(pp_mux mux, int fd, bool enable) {
    if (!mux) return false;
    struct kevent ev;
    EV_SET(&ev, fd, EVFILT_WRITE, enable ? EV_ADD : EV_DELETE, 0, 0, 0);
    const int ret = kevent(mux->handle, &ev, 1, NULL, 0, NULL);
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

int pp_mux_wait(pp_mux mux) {
    if (!mux) return -1;
    const int num = kevent(mux->handle, NULL, 0, mux->events, mux->events_len, NULL);
    for (int i = 0; i < num; ++i) {
        const struct kevent *ev = mux->events + i;
        const int fd = (int)ev->ident;
        if (ev->filter == EVFILT_READ) {
            if (ev->flags & EV_EOF) {
                struct kevent changes[2];
                EV_SET(&changes[0], fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
                EV_SET(&changes[1], fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
                kevent(mux->handle, changes, 2, NULL, 0, NULL);
                // FIXME: ###, Report EOF
                continue;
            }
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
    return kevent(mux->handle, &ev, 1, NULL, 0, NULL) == 0;
}

void pp_mux_stop(pp_mux mux) {
    if (!mux) return;
//    eventf
}

#elif PARTOUT_LINUX || PARTOUT_ANDROID
#include <sys/epoll.h>
#include <unistd.h>

struct __pp_mux {
    int handle;
    struct epoll_event *events;
    int events_len;
};

pp_mux pp_mux_create(int num) {
    int handle = epoll_create(1); /* Size is ignored */
    if (handle < 0) return NULL;
    pp_mux mux = pp_alloc(sizeof(*mux));
    mux->handle = handle;
    mux->events = pp_alloc((1 + num) * sizeof(struct epoll_event));
    mux->events_len = 1 + num;
    return mux;
}

void pp_mux_free(pp_mux mux) {
    if (!mux) return;
    close(mux->handle);
    pp_free(mux->events);
    pp_free(mux);
}

bool pp_mux_add(pp_mux mux, int pos, int fd) {
    if (!mux) return false;
    struct epoll_event *event = &mux->events[pos];
    event->events = EPOLLIN;
    event->data.fd = fd;
    return epoll_ctl(mux->handle, EPOLL_CTL_ADD, fd, event) == 0;
}

bool pp_mux_set_write(pp_mux mux, int pos, int fd, bool enable) {
    if (!mux) return false;
    struct epoll_event *event = &mux->events[pos];
    event->events = enable ? (EPOLLIN | EPOLLOUT) : EPOLLIN;
    event->data.fd = fd;
    return epoll_ctl(mux->handle, EPOLL_CTL_MOD, fd, event) == 0;
}

int pp_mux_wait(pp_mux mux) {
    if (!mux) return -1;
    return epoll_wait(mux->handle, mux->events, mux->events_len, -1);
}
#endif
