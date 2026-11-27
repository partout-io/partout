// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once

// Generated models are statically linked into each consumer.
#define PARTOUT_API

#if !defined(_WIN32)
#define PARTOUT_RUNTIME_API __attribute__((visibility("default")))
#elif defined(PARTOUT_API_BUILD_DLL)
#define PARTOUT_RUNTIME_API __declspec(dllexport)
#elif defined(PARTOUT_API_USE_DLL)
#define PARTOUT_RUNTIME_API __declspec(dllimport)
#else
#define PARTOUT_RUNTIME_API
#endif
