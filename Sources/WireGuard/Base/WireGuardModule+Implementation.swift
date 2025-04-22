//
//  WireGuardModule+Implementation.swift
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

extension WireGuardModule {
    public struct Implementation: ModuleImplementation, Sendable {
        public let moduleHandlerId: ModuleType = .wireGuard

        public let keyGenerator: WireGuardKeyGenerator

        public let importer: ModuleImporter

        public let validator: ModuleBuilderValidator

        public let connectionBlock: @Sendable (ConnectionParameters, WireGuardModule) async throws -> Connection

        public init(
            keyGenerator: WireGuardKeyGenerator,
            importer: ModuleImporter,
            validator: ModuleBuilderValidator,
            connectionBlock: @escaping @Sendable (ConnectionParameters, WireGuardModule) async throws -> Connection
        ) {
            self.keyGenerator = keyGenerator
            self.importer = importer
            self.validator = validator
            self.connectionBlock = connectionBlock
        }
    }
}

extension WireGuardModule.Implementation: ModuleImporter {
    public func module(fromContents contents: String, object: Any?) throws -> Module {
        try importer.module(fromContents: contents, object: object)
    }
}

extension WireGuardModule.Implementation: ModuleBuilderValidator {
    public func validate(_ builder: any ModuleBuilder) throws {
        try validator.validate(builder)
    }
}
