// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once

#if defined(PARTOUT_MODELS_BUILD_DLL)
#define PARTOUT_MODELS_API __declspec(dllexport)
#elif defined(PARTOUT_MODELS_USE_DLL)
#define PARTOUT_MODELS_API __declspec(dllimport)
#else
#define PARTOUT_MODELS_API
#endif
