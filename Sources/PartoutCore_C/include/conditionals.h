/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#define PARTOUT_APPLE       1
#define PARTOUT_MACOS       TARGET_OS_OSX
#else
#define PARTOUT_APPLE       0
#define PARTOUT_MACOS       0
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

#if PARTOUT_MACOS || PARTOUT_LINUX || PARTOUT_WINDOWS
#define PARTOUT_ABI         1
#else
#define PARTOUT_ABI         0
#endif
