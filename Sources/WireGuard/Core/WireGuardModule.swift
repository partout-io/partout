//
//  WireGuardModule.swift
//  Partout
//
//  Created by Davide De Rosa on 3/25/24.
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
    public static let wireGuard = ModuleType("WireGuard")
}

/// A `ConnectionModule` providing a WireGuard connection.
public struct WireGuardModule: Module, BuildableType, Hashable, Codable {
    public static let moduleHandler = ModuleHandler(.wireGuard, WireGuardModule.self)

    public let id: UUID

    public let configuration: WireGuard.Configuration?

    fileprivate init(id: UUID, configuration: WireGuard.Configuration?) {
        self.id = id
        self.configuration = configuration
    }

    public func builder() -> Builder {
        Builder(
            id: id,
            configurationBuilder: configuration?.builder()
        )
    }
}

extension WireGuardModule {
    public struct Builder: ModuleBuilder, Hashable {
        public let id: UUID

        public var configurationBuilder: WireGuard.Configuration.Builder?

        public static func empty() -> Self {
            self.init()
        }

        public init(
            id: UUID = UUID(),
            configurationBuilder: WireGuard.Configuration.Builder? = nil
        ) {
            self.id = id
            self.configurationBuilder = configurationBuilder
        }

        public func tryBuild() throws -> WireGuardModule {
            guard configurationBuilder != nil else {
                throw PartoutError(.incompleteModule, self)
            }
            return WireGuardModule(
                id: id,
                configuration: try configurationBuilder?.tryBuild()
            )
        }
    }
}

extension WireGuardModule: ConnectionModule {

    /// - Throws: If `impl` is not of type ``WireGuardModule/Implementation``.
    public func newConnection(
        with impl: ModuleImplementation?,
        parameters: ConnectionParameters
    ) throws -> Connection {
        guard let impl = impl as? WireGuardModule.Implementation else {
            throw PartoutError(.requiredImplementation)
        }
        return try impl.connectionBlock(parameters, self)
    }
}
