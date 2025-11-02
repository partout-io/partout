// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Returns a `String` representation optionally containing sensitive data.
public protocol SensitiveDebugStringConvertible {
    func debugDescription(withSensitiveData: Bool) -> String
}
