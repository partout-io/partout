// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once

#if defined(PARTOUT_API_BUILD_DLL)
#define PARTOUT_API __declspec(dllexport)
#elif defined(PARTOUT_API_USE_DLL)
#define PARTOUT_API __declspec(dllimport)
#else
#define PARTOUT_API
#endif
