// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Extends a registry with encoding capabilities.
public final class CodingRegistry {
    public typealias PostDecodeBlock = @Sendable (Profile) -> Profile?

    private let registry: Registry
    private let withLegacyEncoding: () -> Bool
    private let postDecodeBlock: PostDecodeBlock?

    public init(
        registry: Registry,
        withLegacyEncoding: @escaping () -> Bool,
        postDecodeBlock: PostDecodeBlock? = nil
    ) {
        self.registry = registry
        self.withLegacyEncoding = withLegacyEncoding
        self.postDecodeBlock = postDecodeBlock ?? Self.migratedProfile
    }
}

extension CodingRegistry: ProfileCoder {
    public func string(fromProfile profile: Profile) throws -> String {
        if withLegacyEncoding() {
            return try rawStringV2(fromProfile: profile)
        }
        return try rawStringV3(fromProfile: profile)
    }

    public func profile(fromString string: String) throws -> Profile {
        let decoders: [DecoderPair] = [
            DecoderPair(version: 3, decoder: rawProfileV3),
            DecoderPair(version: 2, decoder: rawProfileV2),
            DecoderPair(version: 1, decoder: rawProfileV1)
        ]
        var lastError: Error?
        for pair in decoders {
            do {
                let parsed = try pair.decoder(string)
                return postDecodeBlock?(parsed) ?? parsed
            } catch {
//                print("Unable to parse profile V\(pair.version): \(error)")
                lastError = error
            }
        }
        throw lastError ?? PartoutError(.decoding)
    }
}

extension CodingRegistry: ConnectionFactory {
    public func connection(for connectionModule: ConnectionModule, parameters: ConnectionParameters) throws -> Connection {
        try registry.connection(for: connectionModule, parameters: parameters)
    }
}

extension CodingRegistry: Resolver {
    public func resolvedProfile(_ profile: Profile) throws -> Profile {
        try registry.resolvedProfile(profile)
    }

    public func resolvedModule(_ module: Module, in profile: Profile?) throws -> Module {
        try registry.resolvedModule(module, in: profile)
    }
}

extension CodingRegistry: ModuleImporter {
    public func module(fromContents contents: String, object: Any?) throws -> Module {
        try registry.module(fromContents: contents, object: object)
    }
}

extension CodingRegistry: ModuleRegistry {
    public func newModuleBuilder(withModuleType moduleType: ModuleType) -> (any ModuleBuilder)? {
        registry.newModuleBuilder(withModuleType: moduleType)
    }

    public func implementation(for moduleType: ModuleType) -> (any ModuleImplementation)? {
        registry.implementation(for: moduleType)
    }
}

// MARK: - Versions

extension CodingRegistry {
    struct DecoderPair {
        let version: Int
        let decoder: (String) throws -> Profile
    }

    func rawStringV3(fromProfile profile: Profile) throws -> String {
        try ProfileEncoderV3()
            .encode(profile.asTaggedProfile)
    }

    func rawProfileV3(fromString string: String) throws -> Profile {
        try ProfileEncoderV3()
            .decode(string)
            .asProfile()
    }
}

extension CodingRegistry {
    func rawStringV2(fromProfile profile: Profile) throws -> String {
        try LegacyProfileEncoderV2(registry)
            .encode(profile.asCodableProfileV2)
    }

    func rawProfileV2(fromString string: String) throws -> Profile {
        let codableProfile = try LegacyProfileEncoderV2(registry)
            .decode(string)
        return try Profile(codableProfileV2: codableProfile)
    }
}

extension CodingRegistry {
    func rawProfileV1(fromString string: String) throws -> Profile {
        try LegacyProfileEncoderV1()
            .decodedProfile(from: string, with: registry)
    }
}

// MARK: - Migrations

private extension CodingRegistry {
    @Sendable
    static func migratedProfile(_ profile: Profile) -> Profile? {
        do {
            switch profile.version {
            case nil:
                // Set new version at the very least
                let builder = profile.builder(withNewId: false, forUpgrade: true)
                return try builder.build()
            default:
                return nil
            }
        } catch {
            pp_log_id(profile.id, .core, .error, "Unable to migrate profile \(profile.id): \(error)")
            return nil
        }
    }
}
