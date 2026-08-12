// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Provides validation logic for a ``ModuleBuilder``.
public protocol ModuleBuilderValidator: Sendable {
    func validate(_ builder: any ModuleBuilder) throws
}
