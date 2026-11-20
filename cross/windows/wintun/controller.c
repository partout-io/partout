// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "partout_wintun.h"
#include <winsock2.h>
#include <Windows.h>
#include <wintun.h>
#include "portable/common.h"
#include <objbase.h>
#include <stdlib.h>

struct wintun_context {
    HMODULE library;
    WINTUN_ADAPTER_HANDLE adapter;
    WINTUN_SESSION_HANDLE session;
    WINTUN_CLOSE_ADAPTER_FUNC *close_adapter;
    WINTUN_END_SESSION_FUNC *end_session;
    WINTUN_GET_READ_WAIT_EVENT_FUNC *get_read_wait_event;
    WINTUN_RECEIVE_PACKET_FUNC *receive_packet;
    WINTUN_RELEASE_RECEIVE_PACKET_FUNC *release_receive_packet;
    WINTUN_ALLOCATE_SEND_PACKET_FUNC *allocate_send_packet;
    WINTUN_SEND_PACKET_FUNC *send_packet;
};

static void close_tun(void *ctx);
static int read_tun(void *ctx, uint8_t *dst, size_t dst_len);
static int write_tun(void *ctx, const uint8_t *src, size_t src_len);
static intptr_t watch_tun(void *ctx);

static const partout_tun_callbacks tun_callbacks = {
    .read = read_tun,
    .write = write_tun,
    .close = close_tun,
    .watch = watch_tun,
};

static partout_tun open_tun(const char *uuid) {
    if (!uuid) return NULL;
    // Keep the DLL loaded while any returned handle can still be in use.
    HMODULE wintun = LoadLibraryExA("wintun.dll", NULL,
        LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!wintun) {
        pp_clog_v(PPLogLevelFault, "tun_windows: create(), LoadLibraryExA(): %lu", GetLastError());
        return NULL;
    }

    struct wintun_context *tun = calloc(1, sizeof(*tun));
    if (!tun) {
        FreeLibrary(wintun);
        return NULL;
    }
    tun->library = wintun;
    WINTUN_CREATE_ADAPTER_FUNC *create_adapter;
    WINTUN_START_SESSION_FUNC *start_session;
    WINTUN_GET_RUNNING_DRIVER_VERSION_FUNC *get_running_driver_version;
    wchar_t *name = NULL;
#define LOAD_FUNCTION(destination, name) \
    do { \
        *(FARPROC *)&destination = GetProcAddress(wintun, name); \
        if (!destination) goto failure; \
    } while (0)
    LOAD_FUNCTION(create_adapter, "WintunCreateAdapter");
    LOAD_FUNCTION(start_session, "WintunStartSession");
    LOAD_FUNCTION(get_running_driver_version, "WintunGetRunningDriverVersion");
    LOAD_FUNCTION(tun->close_adapter, "WintunCloseAdapter");
    LOAD_FUNCTION(tun->end_session, "WintunEndSession");
    LOAD_FUNCTION(tun->get_read_wait_event, "WintunGetReadWaitEvent");
    LOAD_FUNCTION(tun->receive_packet, "WintunReceivePacket");
    LOAD_FUNCTION(tun->release_receive_packet, "WintunReleaseReceivePacket");
    LOAD_FUNCTION(tun->allocate_send_packet, "WintunAllocateSendPacket");
    LOAD_FUNCTION(tun->send_packet, "WintunSendPacket");
#undef LOAD_FUNCTION

    const int len = MultiByteToWideChar(CP_UTF8, 0, uuid, -1, NULL, 0);
    if (len == 0) {
        pp_clog_v(PPLogLevelFault, "tun_windows: create(), wstring_from_string()");
        goto failure;
    }
    name = pp_alloc(len * sizeof(*name));
    if (!MultiByteToWideChar(CP_UTF8, 0, uuid, -1, name, len)) {
        pp_clog_v(PPLogLevelFault, "tun_windows: create(), wstring_from_string()");
        goto failure;
    }
    GUID guid;
    if (FAILED(CLSIDFromString(name, &guid))) ZeroMemory(&guid, sizeof(guid));
    tun->adapter = create_adapter(name, L"Partout", &guid);
    if (!tun->adapter) {
        pp_clog_v(PPLogLevelFault, "tun_windows: create(), WintunCreateAdapter(): %lu", GetLastError());
        goto failure;
    }
    const DWORD version = get_running_driver_version();
    pp_clog_v(PPLogLevelInfo, "tun_windows: Wintun v%lu.%lu loaded",
        (version >> 16) & 0xff, (version >> 0) & 0xff);
    tun->session = start_session(tun->adapter, WINTUN_MAX_RING_CAPACITY);
    if (!tun->session) {
        pp_clog_v(PPLogLevelFault, "tun_windows: create(), WintunStartSession(): %lu", GetLastError());
        goto failure;
    }
    pp_clog_v(PPLogLevelInfo, "tun_windows: Created wintun device %ls", name);
    partout_tun wrapped = partout_tun_wrap_callbacks(tun, &tun_callbacks);
    if (!wrapped) goto failure;
    free(name);
    return wrapped;

failure:
    free(name);
    close_tun(tun);
    return NULL;
}

static void close_tun(void *ctx) {
    struct wintun_context *tun = ctx;
    if (!tun) return;
    if (tun->session) tun->end_session(tun->session);
    if (tun->adapter) tun->close_adapter(tun->adapter);
    FreeLibrary(tun->library);
    pp_free(tun);
}

static int read_tun(void *ctx, uint8_t *dst, size_t dst_len) {
    const struct wintun_context *tun = ctx;
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
            return PartoutIOWouldBlock;
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

static int write_tun(void *ctx, const uint8_t *src, size_t src_len) {
    const struct wintun_context *tun = ctx;
    if (!tun || !tun->session) {
        SetLastError(ERROR_INVALID_HANDLE);
        return -1;
    }
    if (!src || src_len == 0) return -1;
    BYTE *packet = tun->allocate_send_packet(tun->session, src_len);
    if (!packet) {
        const DWORD err = GetLastError();
        if (err == ERROR_BUFFER_OVERFLOW) {
            return PartoutIONoBufs;
        }
        pp_clog_v(PPLogLevelFault, "tun_windows: write(), %lu", err);
        return -1;
    }
    memcpy(packet, src, src_len);
    tun->send_packet(tun->session, packet);
    return (int)src_len;
}

static intptr_t watch_tun(void *ctx) {
    const struct wintun_context *tun = ctx;
    if (!tun || !tun->session) return (intptr_t)INVALID_HANDLE_VALUE;
    return (intptr_t)tun->get_read_wait_event(tun->session);
}

static partout_tun set_tunnel(void *ctx, const char *uuid, const char *json) {
    (void)ctx;
    (void)json;
    return open_tun(uuid);
}

static void set_delegate(void *ctx, const partout_controller_delegate *delegate) {
    (void)ctx;
    (void)delegate;
}

static void report_snapshot(void *ctx, const char *json) {
    (void)ctx;
    (void)json;
}

static void set_environment(void *ctx, const char *key, const char *json) {
    (void)ctx;
    (void)key;
    (void)json;
}

static void clear_tunnel(void *ctx, bool kill_switch) {
    (void)ctx;
    (void)kill_switch;
}

static void cancel_tunnel(void *ctx, const char *code) {
    (void)ctx;
    (void)code;
}

static bool configure_sockets(void *ctx, const partout_reachability *info,
                               const partout_socket_descriptor *fds, size_t count) {
    (void)ctx;
    (void)info;
    (void)fds;
    (void)count;
    return true;
}

partout_controller_functions partout_wintun_controller_functions(void) {
    const partout_controller_functions functions = {
        .set_delegate = set_delegate,
        .set_tunnel = set_tunnel,
        .report_snapshot = report_snapshot,
        .set_environment_value = set_environment,
        .clear_tunnel = clear_tunnel,
        .cancel_tunnel = cancel_tunnel,
        .configure_sockets = configure_sockets
    };
    return functions;
}
