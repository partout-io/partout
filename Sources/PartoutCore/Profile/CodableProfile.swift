// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Wrapper of ``Profile`` with encoding capabilities.
public struct CodableProfile: ProfileType, Codable {
    public let version: Int?

    public let id: UniqueID

    public let name: String

    public let modules: [CodableModule]

    public let activeModulesIds: Set<UniqueID>

    public let behavior: ProfileBehavior?

    public let userInfo: JSON?
}

/// Wrapper of ``Module`` with encoding capabilities.
public struct CodableModule: Codable {
    enum CodingKeys: CodingKey {
        case moduleType
        case payload
    }

    let moduleType: ModuleType

    let wrappedModule: Module

    init(wrappedModule: Module) {
        moduleType = wrappedModule.moduleHandler.id
        self.wrappedModule = wrappedModule
    }

    public init(from decoder: Decoder) throws {
        guard let moduleDecoder = decoder.userInfo[.moduleDecoder] as? ModuleDecoder else {
            throw PartoutError(.decoding, "Missing module decoder from .userInfo")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        moduleType = try container.decode(ModuleType.self, forKey: .moduleType)
        let payloadDecoder = try container.superDecoder(forKey: .payload)
        let module = try moduleDecoder.decodedModule(from: payloadDecoder, ofType: moduleType)
        assert(module.moduleHandler.id == moduleType, "Deserialized type mismatch")
        wrappedModule = module
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(moduleType, forKey: .moduleType)
        guard let encodableModule = wrappedModule as? Encodable else {
            throw PartoutError(.encoding, "Module not encodable")
        }
        try container.encode(encodableModule, forKey: .payload)
    }
}

extension Profile {
    init(codableProfile: CodableProfile) throws {
        self = try Profile.Builder(
            version: codableProfile.version,
            id: codableProfile.id,
            name: codableProfile.name,
            modules: codableProfile.modules.map(\.wrappedModule),
            activeModulesIds: codableProfile.activeModulesIds,
            behavior: codableProfile.behavior,
            userInfo: codableProfile.userInfo
        ).build()
    }

    var asCodableProfile: CodableProfile {
        CodableProfile(
            version: Profile.Builder.currentVersion,
            id: id,
            name: name,
            modules: modules.map {
                CodableModule(wrappedModule: $0)
            },
            activeModulesIds: activeModulesIds,
            behavior: behavior,
            userInfo: userInfo
        )
    }
}
