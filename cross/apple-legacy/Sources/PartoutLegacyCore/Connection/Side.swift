// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Semantic side of the event loop.
public enum Side: Hashable, Sendable {
    case link
    case tun
}
