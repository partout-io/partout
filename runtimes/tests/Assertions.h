// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once

// Force-included before any test headers so Release builds retain assertions
// without conflicting /D and /U compiler options.
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
