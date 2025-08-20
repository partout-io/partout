// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

extension WireGuardModule {
    public final class Implementation: ModuleImplementation, Sendable {
        public let moduleHandlerId: ModuleType = .wireGuard

        public let keyGenerator: WireGuardKeyGenerator

        public let importer: ModuleImporter

        public let validator: ModuleBuilderValidator

        public let connectionBlock: @Sendable (ConnectionParameters, WireGuardModule) throws -> Connection

        public init(
            keyGenerator: WireGuardKeyGenerator,
            importer: ModuleImporter,
            validator: ModuleBuilderValidator,
            connectionBlock: @escaping @Sendable (ConnectionParameters, WireGuardModule) throws -> Connection
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
