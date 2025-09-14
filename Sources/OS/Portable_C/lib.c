/*
 * SPDX-FileCopyrightText: 2025 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "portable/common.h"
#include "portable/lib.h"

#ifdef _WIN32
#include <windows.h>
struct _pp_lib {
    HMODULE handle;
};
#else
#include <dlfcn.h>
struct _pp_lib {
    void *handle;
};
#endif

#define PP_LIB_EXT_MAXLEN (sizeof("lib.dylib"))

pp_lib pp_lib_create(const char *path) {
    const size_t path_len = strlen(path) + PP_LIB_EXT_MAXLEN;
    char *path_ext = pp_alloc(path_len);
#ifdef _WIN32
    snprintf(path_ext, path_len, "%s.dll", path);
    HMODULE handle = LoadLibraryExA(path_ext, NULL, LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!handle) {
        fprintf(stderr, "LoadLibraryExA(): %lu\n", GetLastError());
        goto failure;
    }
#else
#ifdef __APPLE__
    snprintf(path_ext, path_len, "lib%s.dylib", path);
#else
    snprintf(path_ext, path_len, "lib%s.so", path);
#endif
    void *handle = dlopen(path_ext, RTLD_NOW);
    if (!handle) {
        fprintf(stderr, "dlopen(): %s\n", dlerror());
        goto failure;
    }
#endif
    pp_free(path_ext);

    pp_lib lib = pp_alloc(sizeof(*lib));
    lib->handle = handle;
    return lib;
failure:
    pp_free(path_ext);
    return NULL;
}

void pp_lib_free(pp_lib lib) {
    if (!lib) return;
#ifdef _WIN32
    FreeLibrary(lib->handle);
#else
    dlclose(lib->handle);
#endif
    pp_free(lib);
}

void *pp_lib_load(const pp_lib lib, const char *symbol) {
#ifdef _WIN32
    void *ptr = GetProcAddress(lib->handle, symbol);
#else
    void *ptr = dlsym(lib->handle, symbol);
#endif
    if (!ptr) {
        fprintf(stderr, "%s not found in library\n", symbol);
        return NULL;
    }
    return ptr;
}
