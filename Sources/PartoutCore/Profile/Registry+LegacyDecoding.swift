// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// `Codable` implementation of ``ProfileCoder``.
@available(*, deprecated, message: "#273")
final class CodableProfileCoder {
    init() {
    }
}

// MARK: Decoder

extension CodableProfileCoder {
    @available(*, deprecated, message: "#273")
    func decodedProfile(from base64Encoded: String, with registry: Registry) throws -> Profile {
        guard let data = Data(base64Encoded: base64Encoded) else {
            throw PartoutError(.decoding)
        }
        let decodable = try JSONDecoder().decode(LegacyCodableProfile.self, from: data)
        let handlers = decodable.modules.compactMap { wrapper in
            registry.handler(withId: wrapper.id)
        }
        return try Serialization.decodedProfile(from: decodable, with: handlers.reduce(into: [:]) {
            $0[$1.id] = $1
        })
    }

    @available(*, deprecated, message: "#273")
    func decodedModule(from data: Data, with registry: Registry) throws -> Module {
        let decoder = JSONDecoder()
        let wrapper = try decoder.decode(LegacyModuleWrapper.self, from: data)
        guard let handler = registry.handler(withId: wrapper.id) else {
            throw PartoutError(.decoding)
        }
        let handlers = [wrapper.id: handler]
        return try Serialization.decodedModule(from: decoder, wrapper: wrapper, with: handlers)
    }

    @available(*, deprecated, message: "#273")
    func decodedModule<T>(_ type: T.Type, from data: Data, with registry: Registry) throws -> T where T: Module {
        guard let result = try decodedModule(from: data, with: registry) as? T else {
            throw PartoutError(.decoding)
        }
        return result
    }
}

// MARK: - Helpers

private enum Serialization {
    typealias ModuleHandlersMap = [ModuleType: ModuleHandler]

    static func decodedProfile(from encoded: LegacyCodableProfile, with handlers: ModuleHandlersMap) throws -> Profile {
        let decoder = JSONDecoder()
        let userInfoMap = try encoded.userInfo.map {
            try JSONSerialization.jsonObject(with: $0)
        } ?? nil
        let userInfoJSON = try userInfoMap.map {
            try JSON($0)
        }
        let builder = Profile.Builder(
            version: encoded.version,
            id: encoded.id,
            name: encoded.name,
            modules: encoded.modules.compactMap {
                do {
                    return try decodedModule(from: decoder, wrapper: $0, with: handlers)
                } catch {
                    pp_log_id(encoded.id, .core, .error, "Unable to decode module: \(error)")
                    return nil
                }
            },
            activeModulesIds: encoded.activeModulesIds,
            behavior: encoded.behavior,
            userInfo: userInfoJSON
        )
        return try builder.build()
    }

    static func decodedModule(
        from decoder: JSONDecoder,
        wrapper: LegacyModuleWrapper,
        with handlers: ModuleHandlersMap
    ) throws -> Module {
        guard let type = handlers[wrapper.id] else {
            throw PartoutError.unknownModuleHandler(moduleType: wrapper.id)
        }
        guard let typeDecoder = type.legacyDecoder else {
            assertionFailure("Decoding a module of type '\(wrapper.id)', but its handler has no decoder (did you encode a transient module?)")
            throw PartoutError(.decoding)
        }
        return try typeDecoder(decoder, wrapper.data)
    }
}

private struct LegacyModuleWrapper: Codable {
    let id: ModuleType

    let data: Data

    init(_ module: Module & Encodable) throws {
        id = module.moduleHandler.id
        data = try JSONEncoder().encode(module)
    }
}

private struct LegacyCodableProfile: ProfileType, Codable {
    let version: Int?

    let id: UniqueID

    let name: String

    let modules: [LegacyModuleWrapper]

    let activeModulesIds: Set<UniqueID>

    let behavior: ProfileBehavior?

    let userInfo: Data?
}
