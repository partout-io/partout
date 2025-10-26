// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore

struct MockModule: Module {
    static let moduleHandler = ModuleHandler(ModuleType("mock-module"), decoder: nil, factory: nil)

    var supportedField = 123
}

struct MockUnsupportedModule: Module {
    static let moduleHandler = ModuleHandler(ModuleType("mock-unsupported-module"), decoder: nil, factory: nil)

    let unsupportedField: Int
}
