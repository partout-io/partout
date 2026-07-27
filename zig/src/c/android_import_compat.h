// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

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
