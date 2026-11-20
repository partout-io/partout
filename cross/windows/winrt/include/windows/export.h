// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once

#if defined(PARTOUT_WINRT_BUILD_DLL)
#define PARTOUT_WINRT_API __declspec(dllexport)
#elif defined(PARTOUT_WINRT_USE_DLL)
#define PARTOUT_WINRT_API __declspec(dllimport)
#else
#define PARTOUT_WINRT_API
#endif
