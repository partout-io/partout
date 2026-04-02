// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore

struct MockModule: Module {
    var supportedField = 123
}

struct MockUnsupportedModule: Module {
    let unsupportedField: Int
}
