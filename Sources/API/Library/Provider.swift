// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
import PartoutProviders

public struct Provider: Identifiable, Hashable, CustomStringConvertible, Sendable {
    public let id: ProviderID

    public let description: String

    public let metadata: [ModuleType: Metadata]

    public init(_ id: String, description: String, moduleTypes: [Module.Type]) {
        self.init(id, description: description, metadata: moduleTypes.reduce(into: [:]) {
            $0[$1.moduleHandler.id] = Metadata()
        })
    }

    public init(_ id: String, description: String, handlers: [ModuleHandler]) {
        self.init(id, description: description, metadata: handlers.reduce(into: [:]) {
            $0[$1.id] = Metadata()
        })
    }

    public init(_ id: String, description: String, metadata: [ModuleType: Metadata] = [:]) {
        self.id = ProviderID(rawValue: id)
        self.description = description
        self.metadata = metadata
    }
}

extension Provider {
    public func supports(_ moduleType: ModuleType) -> Bool {
        metadata.keys.contains(moduleType)
    }

    public func supports<M>(_ moduleType: M.Type) -> Bool where M: Module {
        metadata.keys.contains(moduleType.moduleHandler.id)
    }

    public func customization<M>(for moduleType: M.Type) -> M.ProviderCustomization? where M: Module, M: ProviderCustomizationSupporting {
        guard let cfg = metadata[moduleType.moduleHandler.id] else {
            return nil
        }
        return M.ProviderCustomization(userInfo: cfg.userInfo)
    }
}
