// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@_exported import PartoutCore
@_exported import PartoutNative_C

public final class PartoutRuntime: Sendable {
    /// The library version.
    public static var version: String {
        guard let cVersion = partout_version() else {
            return "undefined"
        }
        return String(cString: cVersion)
    }

    /// The library identifier and version.
    public static var versionIdentifier: String {
        "\(PartoutCore.identifier) \(version)"
    }

    public init() {}

    public func importProfile(from url: URL) throws -> Profile {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try importProfile(from: text, name: url.lastPathComponent)
    }

    public func importProfile(from text: String, name: String?) throws -> Profile {
        guard let cJSON = partout_import_profile(text, name) else {
            throw PartoutError(.decoding)
        }
        defer { free(cJSON) }
        let json = String(cString: cJSON)
        guard let jsonData = json.data(using: .utf8) else {
            throw PartoutError(.decoding)
        }
        let tagged = try abiPayload(TaggedProfile.self, from: jsonData)
        return try tagged.asProfile()
    }

    public func importModule(
        from url: URL,
        context: ModuleImportContext? = nil
    ) throws -> Module {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try importModule(from: text, context: context)
    }

    public func importModule(
        from text: String,
        context: ModuleImportContext? = nil
    ) throws -> Module {
        let contextJSON = try context.map { try JSONEncoder.shared().encodeJSON($0) }
        guard let cJSON = partout_import_module(text, contextJSON) else {
            throw PartoutError(.decoding)
        }
        defer { free(cJSON) }
        let json = String(cString: cJSON)
        guard let jsonData = json.data(using: .utf8) else {
            throw PartoutError(.decoding)
        }
        let tagged = try abiPayload(TaggedModule.self, from: jsonData)
        return tagged.containedModule
    }

    public func exportModule(_ module: Module) throws -> String {
        guard let tagged = module.taggedModule else {
            throw PartoutError(.decoding)
        }
        let json = try JSONEncoder.shared().encodeJSON(tagged)
        guard let cText = partout_export_module(json) else {
            throw PartoutError(.encoding)
        }
        defer { free(cText) }
        return String(cString: cText)
    }

    public func wireGuardGeneratePrivateKey() throws -> String {
        guard let cKey = partout_wireguard_genkey() else {
            throw PartoutError(.crypto)
        }
        defer { free(cKey) }
        return String(cString: cKey)
    }

    public func wireGuardDerivePublicKey(privateKey: String) throws -> String {
        let cPubKey = privateKey.withCString {
            partout_wireguard_pubkey($0)
        }
        guard let cPubKey else {
            throw PartoutError(.crypto)
        }
        defer { free(cPubKey) }
        return String(cString: cPubKey)
    }
}

private extension PartoutRuntime {
    func abiPayload<T>(_ type: T.Type, from data: Data) throws -> T where T: Decodable {
        let decoder = JSONDecoder.shared()
        let envelope = try decoder.decode(ABIEnvelope.self, from: data)
        if let code = envelope.code {
            if let payload = envelope.payload {
                throw PartoutError(code, payload: payload)
            }
            throw PartoutError(code)
        }
        guard let payload = envelope.payload else {
            throw PartoutError(.decoding)
        }
        let encoder = JSONEncoder.shared()
        let payloadData = try encoder.encode(payload)
        return try decoder.decode(type, from: payloadData)
    }
}
