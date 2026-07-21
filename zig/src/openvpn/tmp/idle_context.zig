// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// State retained between session attempts.
pub const IdleContext = struct {
    /// Cleared after AUTH_FAILED so the next attempt sends `V0 UNDEF`.
    with_local_options: bool = true,
};
