// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

public protocol ProviderTemplateCompiler {
    associatedtype CompiledModule: Module

    associatedtype Options: ProviderOptions

    static func compiled(
        _ ctx: PartoutLoggerContext,
        moduleId: UUID,
        entity: ProviderEntity,
        options: Options?,
        userInfo: [String: Any]?
    ) throws -> CompiledModule
}

extension ProviderTemplateCompiler {
    public var moduleType: ModuleType {
        CompiledModule.moduleHandler.id
    }
}

extension ProviderModule {
    public func compiled<T>(
        _ ctx: PartoutLoggerContext,
        withTemplate templateType: T.Type,
        userInfo: [String: Any]?
    ) throws -> Module where T: ProviderTemplateCompiler {
        guard let entity else {
            throw PartoutError(.Providers.missingEntity)
        }
        let options: T.Options? = try options(for: providerModuleType)
        return try T.compiled(
            ctx,
            moduleId: id,
            entity: entity,
            options: options,
            userInfo: userInfo
        )
    }
}
