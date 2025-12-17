// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension WireGuardModule {
    public final class Implementation: ModuleImplementation, Sendable {
        public let moduleHandlerId: ModuleType = .wireGuard

        public let keyGenerator: WireGuardKeyGenerator

        public let importerBlock: @Sendable () -> ModuleImporter

        public let validatorBlock: @Sendable () -> ModuleBuilderValidator

        public let connectionBlock: @Sendable (ConnectionParameters, WireGuardModule) throws -> Connection

        public init(
            keyGenerator: WireGuardKeyGenerator,
            importerBlock: @escaping @Sendable () -> ModuleImporter,
            validatorBlock: @escaping @Sendable () -> ModuleBuilderValidator,
            connectionBlock: @escaping @Sendable (ConnectionParameters, WireGuardModule) throws -> Connection
        ) {
            self.keyGenerator = keyGenerator
            self.importerBlock = importerBlock
            self.validatorBlock = validatorBlock
            self.connectionBlock = connectionBlock
        }
    }
}

extension WireGuardModule.Implementation: ModuleImporter {
    public func module(fromContents contents: String, object: Any?) throws -> Module {
        try importerBlock().module(fromContents: contents, object: object)
    }
}

extension WireGuardModule.Implementation: ModuleBuilderValidator {
    public func validate(_ builder: any ModuleBuilder) throws {
        try validatorBlock().validate(builder)
    }
}
