// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Lifecycle phase of an active OpenVPN session.
pub const ActivePhase = enum {
    starting,
    started,
    stopping,
};
