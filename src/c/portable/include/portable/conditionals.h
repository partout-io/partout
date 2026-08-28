/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

/*
 * Zig 0.16 cannot translate nullability qualifiers placed inside array
 * declarators in the Android NDK headers. Import the affected headers once
 * without those qualifiers, then restore the qualifiers before importing
 * Partout's own annotated headers.
 */
#if defined(__ANDROID__)
#define _Nonnull
#define _Nullable
#define _Null_unspecified

#include <stdlib.h>
#include <sys/socket.h>

#undef _Null_unspecified
#undef _Nullable
#undef _Nonnull
#endif

#if defined(__APPLE__)
#include <TargetConditionals.h>
#define PARTOUT_APPLE       1
#if TARGET_OS_OSX
#define PARTOUT_MACOS       1
#else
#define PARTOUT_MACOS       0
#endif
#else
#define PARTOUT_APPLE       0
#endif

#if defined(__ANDROID__)
#define PARTOUT_ANDROID     1
#define PARTOUT_LINUX       0
#elif defined(__linux__)
#define PARTOUT_ANDROID     0
#define PARTOUT_LINUX       1
#else
#define PARTOUT_ANDROID     0
#define PARTOUT_LINUX       0
#endif

#if defined(_WIN32)
#define PARTOUT_WINDOWS     1
#else
#define PARTOUT_WINDOWS     0
#endif

#if PARTOUT_WINDOWS
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif

#if defined(PARTOUT_CRYPTO_OPENSSL) || defined(PARTOUT_CRYPTO_MBEDTLS)
#define PARTOUT_HAS_CRYPTO 1
#else
#define PARTOUT_HAS_CRYPTO 0
#endif

#ifndef PARTOUT_HAS_WIREGUARD_BACKEND
#define PARTOUT_HAS_WIREGUARD_BACKEND 1
#endif
