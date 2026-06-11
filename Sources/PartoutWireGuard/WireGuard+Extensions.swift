// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE
@_exported import PartoutCore
#endif

extension WireGuardModule: SerializableModule, ConnectionModule {
    public var preferredExtension: String {
        "conf"
    }

    public func serialized() throws -> String {
        guard let configuration else {
            throw PartoutError(.incompleteModule, self)
        }
        return try configuration.serialized()
    }

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

extension WireGuard.Configuration: SerializableConfiguration {
    public func serialized() throws -> String {
        asWgQuickConfig()
    }
}

extension WireGuard.LocalInterface.Builder {
    public init(keyGenerator: WireGuardKeyGenerator) {
        self.init(privateKey: keyGenerator.newPrivateKey())
    }
}

extension WireGuard.Configuration.Builder {
    public init(keyGenerator: WireGuardKeyGenerator) {
        self.init(
            interface: WireGuard.LocalInterface.Builder(keyGenerator: keyGenerator),
            peers: []
        )
    }
}

extension WireGuardParseError: PartoutErrorMappable {
    public var asPartoutError: PartoutError {
        PartoutError(.parsing, self)
    }
}
