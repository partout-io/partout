/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "portable/mux.h"
#include <errno.h>

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

bool pp_mux_set_read(pp_mux mux, int fd, bool enable) {
    if (!mux) return false;
    struct kevent ev;
    EV_SET(&ev, fd, EVFILT_READ, enable ? EV_ADD : EV_DELETE, 0, 0, 0);
    const int ret = kevent(mux->handle, &ev, 1, NULL, 0, NULL);
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

#elif PARTOUT_LINUX || PARTOUT_ANDROID
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

#ifndef EPOLLRDHUP
#define EPOLLRDHUP 0
#endif

struct __pp_mux {
    int handle;
    int wake_fd;
    struct epoll_event *events;
    int events_len;
    void (*on_readable)(void *ctx, int fd);
    void (*on_writable)(void *ctx, int fd);
    void *read_ctx;
    void *write_ctx;
};

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
    pp_free(mux);
}

bool pp_mux_add(pp_mux mux, int fd) {
    if (!mux) return false;
    struct epoll_event ev;
    pp_zero(&ev, sizeof(ev));
    ev.events = EPOLLIN | EPOLLERR | EPOLLHUP | EPOLLRDHUP;
    ev.data.fd = fd;
    const int ret = epoll_ctl(mux->handle, EPOLL_CTL_ADD, fd, &ev);
    if (ret < 0) {
        if (errno == EEXIST) return true;
        return false;
    }
    return true;
}

bool pp_mux_set_write(pp_mux mux, int fd, bool enable) {
    if (!mux) return false;
    struct epoll_event ev;
    pp_zero(&ev, sizeof(ev));
    ev.events = EPOLLIN | EPOLLERR | EPOLLHUP | EPOLLRDHUP;
    if (enable) {
        ev.events |= EPOLLOUT;
    }
    ev.data.fd = fd;
    const int ret = epoll_ctl(mux->handle, EPOLL_CTL_MOD, fd, &ev);
    if (ret < 0) {
        if (enable && errno == ENOENT) {
            return epoll_ctl(mux->handle, EPOLL_CTL_ADD, fd, &ev) == 0;
        }
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
    const int num = epoll_wait(mux->handle, mux->events, mux->events_len, -1);
    for (int i = 0; i < num; ++i) {
        const struct epoll_event *ev = mux->events + i;
        const int fd = ev->data.fd;
        if (fd == mux->wake_fd) {
            eventfd_t value;
            while (true) {
                if (eventfd_read(mux->wake_fd, &value) == 0) {
                    continue;
                }
                if (errno == EINTR) {
                    continue;
                }
                break;
            }
            continue;
        }
        const bool failed = ev->events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP);
        const bool readable = (ev->events & EPOLLIN) || failed;
        const bool writable = ev->events & EPOLLOUT;
        bool did_notify_readable = false;
        if (readable && mux->on_readable) {
            mux->on_readable(mux->read_ctx, fd);
            did_notify_readable = true;
        }
        if ((writable || (!did_notify_readable && failed)) && mux->on_writable) {
            mux->on_writable(mux->write_ctx, fd);
        }
    }
    return num;
}

bool pp_mux_wake(pp_mux mux) {
    if (!mux) return false;
    if (eventfd_write(mux->wake_fd, 1) == 0) return true;
    return errno == EAGAIN;
}
#endif
