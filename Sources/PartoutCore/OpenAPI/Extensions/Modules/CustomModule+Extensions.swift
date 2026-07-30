// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension CustomModule: Module {
    public static let moduleType: ModuleType = .Custom

    public init(_ module: Module & Encodable) throws {
        self.init(
            innerType: module.moduleType,
            json: try JSON(encodable: module)
        )
    }
}
