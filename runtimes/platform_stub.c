// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#include <partout.h>

#if defined(__GNUC__)
__attribute__((visibility("default")))
#endif
bool partout_platform_bindings_init(partout_daemon_bindings *bindings) {
    (void)bindings;
    return false;
}
