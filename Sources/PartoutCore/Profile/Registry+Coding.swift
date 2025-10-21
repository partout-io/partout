// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension Registry {
    public func json(fromProfile profile: Profile) throws -> String {
        let encoder = JSONEncoder()
        let codableProfile = CodableProfile(
            version: Profile.Builder.currentVersion,
            id: profile.id,
            name: profile.name,
            modules: profile.modules.map {
                CodableModule(wrappedModule: $0)
            },
            activeModulesIds: profile.activeModulesIds,
            behavior: profile.behavior,
            userInfo: profile.userInfo
        )
        let data = try encoder.encode(codableProfile)
        guard let json = String(data: data, encoding: .utf8) else {
            throw PartoutError(.encoding)
        }
        return json
    }

    public func profile(fromJSON json: String) throws -> Profile {
        guard let data = json.data(using: .utf8) else {
            throw PartoutError(.decoding, "Not a UTF-8 input")
        }
        let decoder = JSONDecoder()
        decoder.userInfo = [.moduleDecoder: self]
        let codableProfile = try decoder.decode(CodableProfile.self, from: data)
        let builder = Profile.Builder(
            version: codableProfile.version,
            id: codableProfile.id,
            name: codableProfile.name,
            modules: codableProfile.modules.map(\.wrappedModule),
            activeModulesIds: codableProfile.activeModulesIds,
            behavior: codableProfile.behavior,
            userInfo: codableProfile.userInfo
        )
        let profile = try builder.build()
        return postDecodeBlock?(profile) ?? profile
    }
}

extension CodingUserInfoKey {
    static let moduleDecoder = CodingUserInfoKey(rawValue: "moduleDecoder")!
}

// MARK: - Codable helpers

struct CodableProfile: ProfileType, Codable {
    let version: Int?

    let id: UniqueID

    let name: String

    let modules: [CodableModule]

    let activeModulesIds: Set<UniqueID>

    let behavior: ProfileBehavior?

    let userInfo: JSON?
}

struct CodableModule: Codable {
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(moduleType, forKey: .moduleType)
        guard let encodableModule = wrappedModule as? Encodable else {
            throw PartoutError(.encoding, "Module not encodable")
        }
        try container.encode(encodableModule, forKey: .payload)
    }
}
