//
//  ProviderModule.swift
//  Partout
//
//  Created by Davide De Rosa on 3/15/25.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import PartoutCore

extension ModuleType {
    public static let provider = ModuleType("Provider")
}

public struct ProviderModule: Module, BuildableType, Hashable, Codable {
    public static let moduleHandler = ModuleHandler(.provider, ProviderModule.self)

    public let id: UUID

    public let providerId: ProviderID

//    public let authentication: ProviderAuthentication

    public let providerModuleType: ModuleType

    public let moduleOptions: [ModuleType: Data]?

    public let entity: ProviderEntity?

    fileprivate init(
        id: UUID,
        providerId: ProviderID,
        providerModuleType: ModuleType,
        moduleOptions: [ModuleType: Data]?,
        entity: ProviderEntity?
    ) {
        self.id = id
        self.providerId = providerId
        self.providerModuleType = providerModuleType
        self.moduleOptions = moduleOptions
        self.entity = entity
    }

    public var isFinal: Bool {
        false
    }

    public func options<O>(for moduleType: ModuleType) -> O? where O: ProviderOptions {
        moduleOptions?.options(for: moduleType)
    }

    public func builder() -> Builder {
        Builder(
            id: id,
            providerId: providerId,
            providerModuleType: providerModuleType,
            moduleOptions: moduleOptions,
            entity: entity
        )
    }
}

extension ProviderModule {
    public struct Builder: ModuleBuilder, Hashable {
        public let id: UUID

        public var providerId: ProviderID? {
            didSet {
                providerModuleType = nil
            }
        }

        public var providerModuleType: ModuleType? {
            didSet {
                entity = nil
            }
        }

        public var moduleOptions: [ModuleType: Data]?

        public var entity: ProviderEntity?

        public static func empty() -> Self {
            self.init()
        }

        public init(
            id: UUID = UUID(),
            providerId: ProviderID? = nil,
            providerModuleType: ModuleType? = nil,
            moduleOptions: [ModuleType: Data]? = nil,
            entity: ProviderEntity? = nil
        ) {
            self.id = id
            self.providerId = providerId
            self.providerModuleType = providerModuleType
            self.moduleOptions = moduleOptions
            self.entity = entity
        }

        public func options<O>(for moduleType: ModuleType) -> O? where O: ProviderOptions {
            moduleOptions?.options(for: moduleType)
        }

        public mutating func setOptions<O>(_ options: O, for moduleType: ModuleType) throws where O: ProviderOptions {
            let encoded = try JSONEncoder().encode(options)
            if moduleOptions == nil {
                moduleOptions = [moduleType: encoded]
            } else {
                moduleOptions?[moduleType] = encoded
            }
        }

        public func tryBuild() throws -> ProviderModule {
            guard let providerId, let providerModuleType else {
                throw PartoutError(.incompleteModule, self)
            }
            return ProviderModule(
                id: id,
                providerId: providerId,
                providerModuleType: providerModuleType,
                moduleOptions: moduleOptions,
                entity: entity
            )
        }
    }
}

extension ProviderModule {
    public func checkCompatible(with otherModule: Module, activeIds: Set<UUID>) throws {
        precondition(otherModule.id != id)
        if !isMutuallyExclusive {
            return
        }
        guard !(otherModule is Self) else {
            throw PartoutError(.incompatibleModules, [self, otherModule])
        }
        guard (otherModule as? ProviderModule)?.providerModuleType != moduleHandler.id else {
            throw PartoutError(.incompatibleModules, [self, otherModule])
        }
    }
}

public protocol ProviderModuleResolver: Sendable {
    var moduleType: ModuleType { get }

    func resolved(from providerModule: ProviderModule) throws -> Module
}

private extension Dictionary where Key == ModuleType, Value == Data {
    func options<O>(for moduleType: ModuleType) -> O? where O: ProviderOptions {
        guard let data = self[moduleType] else {
            return nil
        }
        return try? JSONDecoder().decode(O.self, from: data)
    }
}
