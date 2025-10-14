// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

public protocol ModuleBuilderValidator: Sendable {
    func validate(_ builder: any ModuleBuilder) throws
}
