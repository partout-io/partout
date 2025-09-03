/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <wintun.h>
#include "portable/common.h"
#include "portable/tun.h"

// FIXME: #188, convert debug messages to logs

struct _pp_tun {
    LPWSTR name;
    WINTUN_ADAPTER_HANDLE adapter;
    WINTUN_SESSION_HANDLE session;
};

static HMODULE wintun;
static WINTUN_CREATE_ADAPTER_FUNC *WintunCreateAdapter;
static WINTUN_CLOSE_ADAPTER_FUNC *WintunCloseAdapter;
// static WINTUN_OPEN_ADAPTER_FUNC *WintunOpenAdapter;
// static WINTUN_GET_ADAPTER_LUID_FUNC *WintunGetAdapterLUID;
static WINTUN_GET_RUNNING_DRIVER_VERSION_FUNC *WintunGetRunningDriverVersion;
// static WINTUN_DELETE_DRIVER_FUNC *WintunDeleteDriver;
// static WINTUN_SET_LOGGER_FUNC *WintunSetLogger;
static WINTUN_START_SESSION_FUNC *WintunStartSession;
static WINTUN_END_SESSION_FUNC *WintunEndSession;
static WINTUN_GET_READ_WAIT_EVENT_FUNC *WintunGetReadWaitEvent;
static WINTUN_RECEIVE_PACKET_FUNC *WintunReceivePacket;
static WINTUN_RELEASE_RECEIVE_PACKET_FUNC *WintunReleaseReceivePacket;
static WINTUN_ALLOCATE_SEND_PACKET_FUNC *WintunAllocateSendPacket;
static WINTUN_SEND_PACKET_FUNC *WintunSendPacket;

#define PP_LOAD_FUNC(lib, name)                         \
    do {                                                \
        *(FARPROC *)&name = GetProcAddress(lib, #name); \
        assert(name && #name " not found in DLL");      \
    } while (0)

pp_tun pp_tun_create(const void *_Nullable impl) {
    (void)impl;
    WINTUN_ADAPTER_HANDLE adapter = NULL;
    WINTUN_SESSION_HANDLE session = NULL;

    // Load DLL before anything (do it once)
    if (!wintun) {
        wintun = LoadLibraryExW(L"wintun.dll", NULL, LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!wintun) {
            fprintf(stderr, "LoadLibraryExW(): %lu\n", GetLastError());
            goto failure;
        }
        // Required DLL functions
        PP_LOAD_FUNC(wintun, WintunCreateAdapter);
        PP_LOAD_FUNC(wintun, WintunCloseAdapter);
        PP_LOAD_FUNC(wintun, WintunGetRunningDriverVersion);
        PP_LOAD_FUNC(wintun, WintunStartSession);
        PP_LOAD_FUNC(wintun, WintunEndSession);
        PP_LOAD_FUNC(wintun, WintunGetReadWaitEvent);
        PP_LOAD_FUNC(wintun, WintunReceivePacket);
        PP_LOAD_FUNC(wintun, WintunReleaseReceivePacket);
        PP_LOAD_FUNC(wintun, WintunAllocateSendPacket);
        PP_LOAD_FUNC(wintun, WintunSendPacket);
    }

    // FIXME: #188, should use profile name and UUID
    LPCWSTR tun_type = L"Partout";
    LPCWSTR dev_name = L"foobar";
    GUID dev_guid = { 0xdeadbabe, 0xcafe, 0xbeef, { 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef } };

    adapter = WintunCreateAdapter(dev_name, tun_type, &dev_guid);
    if (!adapter) {
        fprintf(stderr, "WintunCreateAdapter(): %lu\n", GetLastError());
        goto failure;
    }

    DWORD version = WintunGetRunningDriverVersion();
    printf("tun_windows: Wintun v%lu.%lu loaded\n", (version >> 16) & 0xff, (version >> 0) & 0xff);

    // Create a session with a 4MB ring buffer
    session = WintunStartSession(adapter, WINTUN_MAX_RING_CAPACITY);
    if (!session) {
        fprintf(stderr, "WintunStartSession(): %lu\n", GetLastError());
        goto failure;
    }
    // printf("tun_windows: adapter is %p, session is %p\n", adapter, session);

    printf("tun_windows: Created wintun device %ls\n", dev_name);
    pp_tun tun = pp_alloc(sizeof(*tun));
    tun->name = _wcsdup(dev_name);
    tun->adapter = adapter;
    tun->session = session;
    return tun;

failure:
    if (session) WintunEndSession(session);
    if (adapter) WintunCloseAdapter(adapter);
    if (wintun) FreeLibrary(wintun);
    return NULL;
}

void pp_tun_free(pp_tun tun) {
    if (!tun) return;
    WintunEndSession(tun->session);
    WintunCloseAdapter(tun->adapter);
    pp_free(tun->name);
    pp_free(tun);

    // XXX: Static library allocations are retained
    // FreeLibrary(wintun);
}

int pp_tun_read(const pp_tun tun, uint8_t *dst, size_t dst_len) {
    DWORD packet_len;
    BYTE *packet = NULL;
    while (!packet) {
        // printf(">>> tun_read looping, packet is %p, session is %p\n", packet, tun->session);
        packet = WintunReceivePacket(tun->session, &packet_len);
        // printf(">>> tun_read received: %p\n", packet);
        if (packet) break;
        const DWORD err = GetLastError();
        if (err != ERROR_NO_MORE_ITEMS) {
            fprintf(stderr, "Packet read failed: %lu\n", err);
            return -1;
        }
        WaitForSingleObject(WintunGetReadWaitEvent(tun->session), INFINITE);
    }
    // FIXME: #188, dst_len must accomodate max packet_len (can we know the MTU beforehand?)
    // WINTUN_MAX_IP_PACKET_SIZE
    // printf(">>> tun_read read %lu bytes\n", packet_len);
    assert(dst_len >= packet_len);
    if (dst_len >= packet_len) {
        memcpy(dst, packet, packet_len);
    }
    WintunReleaseReceivePacket(tun->session, packet);
    // printf(">>> tun_read released\n");
    return packet_len;
}

int pp_tun_write(const pp_tun tun, const uint8_t *src, size_t src_len) {
    // printf(">>> tun_write write %llu bytes\n", src_len);
    BYTE *packet = WintunAllocateSendPacket(tun->session, src_len);
    if (!packet) {
        const DWORD err = GetLastError();
        // Silently drop packets if the ring is full
        if (err == ERROR_BUFFER_OVERFLOW) return 0;
        fprintf(stderr, "Packet write failed: %lu\n", err);
        return -1;
    }
    // printf(">>> tun_write allocated\n");
    memcpy(packet, src, src_len);
    WintunSendPacket(tun->session, packet);
    // printf(">>> tun_write written\n");
    return src_len;
}

int pp_tun_fd(const pp_tun tun) {
    return -1;
}

const char *pp_tun_name(const pp_tun tun) {
    return NULL;
}
