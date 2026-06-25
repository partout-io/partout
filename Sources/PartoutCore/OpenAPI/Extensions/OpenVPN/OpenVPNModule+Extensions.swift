// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPNModule: Module, BuildableType {
    public static let moduleType: ModuleType = .OpenVPN

    public var isInteractive: Bool {
        if requiresCredentials {
            return true
        }
        return configuration?.staticChallenge ?? requiresInteractiveCredentials ?? false
    }

    public func builder() -> Builder {
        Builder(
            id: id,
            configurationBuilder: configuration?.builder(),
            credentials: credentials,
            isInteractive: requiresInteractiveCredentials ?? false
        )
    }
}

private extension OpenVPNModule {
    var requiresCredentials: Bool {
        guard configuration?.authUserPass == true else {
            return false
        }
        return credentials?.isEmpty ?? true
    }
}

extension OpenVPNModule {
    public struct Builder: ModuleBuilder, Hashable {
        public var id: UniqueID
        public var configurationBuilder: OpenVPN.Configuration.Builder?
        public var credentials: OpenVPN.Credentials?
        public var isInteractive: Bool

        public static func empty() -> Self {
            self.init()
        }

        public init(
            id: UniqueID = UniqueID(),
            configurationBuilder: OpenVPN.Configuration.Builder? = nil,
            credentials: OpenVPN.Credentials? = nil,
            isInteractive: Bool = false
        ) {
            self.id = id
            self.configurationBuilder = configurationBuilder
            self.credentials = credentials
            self.isInteractive = isInteractive
        }

        public func build() throws -> OpenVPNModule {
            guard configurationBuilder != nil else {
                throw PartoutError(.incompleteModule, self)
            }
            var builder = configurationBuilder
            builder?.staticChallenge = isInteractive
            let configuration = try builder?.build(isClient: true)
            return OpenVPNModule(
                id: id,
                configuration: configuration,
                credentials: credentials,
                requiresInteractiveCredentials: isInteractive
            )
        }
    }
}

extension PartoutError.ModuleField {
    public enum OpenVPN {
        private static let root = "OpenVPN"
        public static let ca = PartoutError.ModuleField("\(root).ca")
        public static let remotes = PartoutError.ModuleField("\(root).remotes")
    }
}
