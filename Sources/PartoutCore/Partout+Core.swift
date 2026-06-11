// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE
@_exported import MiniFoundation
#endif

extension LoggerCategory {
    public static let core = Self(rawValue: "core")
}
