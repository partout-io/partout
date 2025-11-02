// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension Registry {
    public func json(fromProfiles profiles: [Profile]) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(profiles.map(\.asCodableProfile))
        guard let json = String(data: data, encoding: .utf8) else {
            throw PartoutError(.encoding)
        }
        return json
    }

    public func json(fromProfile profile: Profile) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(profile.asCodableProfile)
        guard let json = String(data: data, encoding: .utf8) else {
            throw PartoutError(.encoding)
        }
        return json
    }

    // Tolerate older encoding
    public func compatibleProfile(fromString string: String, fallingBack: Bool = true) throws -> Profile {
        do {
            return try profile(fromJSON: string)
        } catch {
            guard fallingBack else {
                throw error
            }
            let decoded = try CodableProfileCoder().decodedProfile(from: string, with: self)
            return postDecodeBlock?(decoded) ?? decoded
        }
    }

    public func profile(fromJSON json: String) throws -> Profile {
        guard let data = json.data(using: .utf8) else {
            throw PartoutError(.decoding, "Not a UTF-8 input")
        }
        let decoder = JSONDecoder()
        decoder.userInfo = [.moduleDecoder: self]
        let codableProfile = try decoder.decode(CodableProfile.self, from: data)
        let profile = try Profile(codableProfile: codableProfile)
        return postDecodeBlock?(profile) ?? profile
    }

    public func profiles(fromJSON json: String) throws -> [Profile] {
        guard let data = json.data(using: .utf8) else {
            throw PartoutError(.decoding, "Not a UTF-8 input")
        }
        let decoder = JSONDecoder()
        decoder.userInfo = [.moduleDecoder: self]
        let codableProfiles: [CodableProfile]
        do {
            codableProfiles = try decoder.decode([CodableProfile].self, from: data)
        } catch {
            codableProfiles = [try decoder.decode(CodableProfile.self, from: data)]
        }
        return try codableProfiles.map {
            let profile = try Profile(codableProfile: $0)
            return postDecodeBlock?(profile) ?? profile
        }
    }
}

extension CodingUserInfoKey {
    static let moduleDecoder = CodingUserInfoKey(rawValue: "moduleDecoder")!
}

// MARK: - Codable helpers

private extension Profile {
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

private struct CodableProfile: ProfileType, Codable {
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
