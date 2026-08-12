// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !USE_CMAKE
@_exported import PartoutCore
#endif

extension OpenVPNModule: ConnectionModule {
    /// - Throws: If `impl` is not of type ``OpenVPNModule/Implementation``.
    public func newConnection(
        with impl: ModuleImplementation?,
        parameters: ConnectionParameters
    ) throws -> Connection {
        guard let impl = impl as? Implementation else {
            throw PartoutError(.requiredImplementation)
        }
        return try impl.connectionBlock(parameters, self)
    }
}

extension OpenVPNModule: SerializableModule {
    public var preferredExtension: String {
        "ovpn"
    }

    public func serialized() throws -> String {
        guard let configuration else {
            throw PartoutError(.incompleteModule, self)
        }
        return try configuration.serialized()
    }
}

extension OpenVPN.Configuration: SerializableConfiguration {
    public func serialized() throws -> String {
        try asOvpnConfig()
    }
}

extension OpenVPN.CryptoContainer {
    public func decrypted(with decrypter: KeyDecrypter, passphrase: String) throws -> OpenVPN.CryptoContainer {
        let decryptedPEM = try decrypter.decryptedKey(fromPEM: pem, passphrase: passphrase)
        return OpenVPN.CryptoContainer(pem: decryptedPEM)
    }
}

extension TunnelEnvironmentKeys {
    public enum OpenVPN {
        public static let serverConfiguration = TunnelEnvironmentKey<OpenVPNConfiguration>("OpenVPN.serverConfiguration")
    }
}
