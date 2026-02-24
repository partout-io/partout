/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: MIT
 */

#include "mini_foundation.h"

#ifndef _WIN32
#include <stdio.h>
#include <stdlib.h>
#include <sys/utsname.h>

void minif_os_get_version(int *major, int *minor, int *patch) {
    struct utsname uts;
    if (uname(&uts) != 0) {
        *major = *minor = *patch = 0;
        return;
    }
    // uts.release looks like: "6.8.0-41-generic"
    sscanf(uts.release, "%d.%d.%d", major, minor, patch);
}

// Dynamically allocated
const char *minif_os_alloc_temp_dir() {
    const char *dir = getenv("TMPDIR");
    if (!dir) dir = P_tmpdir;
    if (!dir) dir = "/tmp";
    return minif_strdup(dir);
}
#else
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

void minif_os_get_version(int *major, int *minor, int *patch) {
    OSVERSIONINFOEXW v = { 0 };
    v.dwOSVersionInfoSize = sizeof(v);
    typedef LONG (WINAPI *RtlGetVersionPtr)(PRTL_OSVERSIONINFOW);
    HMODULE h = GetModuleHandleW(L"ntdll.dll");
    RtlGetVersionPtr rtlGetVersion = (RtlGetVersionPtr)GetProcAddress(h, "RtlGetVersion");
    if (!(rtlGetVersion && rtlGetVersion((PRTL_OSVERSIONINFOW)&v) == 0)) {
        return;
    }
    *major = v.dwMajorVersion;
    *minor = v.dwMinorVersion;
    *patch = v.dwBuildNumber;
}

const char *minif_os_alloc_temp_dir() {
    char path[MAX_PATH] = { 0 };
    DWORD n = GetTempPathA(MAX_PATH, path);
    if (n <= 0 || n >= MAX_PATH) {
        strncpy_s(path, sizeof(path), "C:\\Temp", _TRUNCATE);
    }
    return minif_strdup(path);
}
#endif
