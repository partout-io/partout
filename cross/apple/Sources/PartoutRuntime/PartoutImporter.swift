// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public final class PartoutImporter: Sendable {
    public init() {}

    public func importProfile(from url: URL) throws -> Profile {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try importProfile(from: text, name: url.lastPathComponent)
    }

    public func importProfile(from text: String, name: String?) throws -> Profile {
        guard let cJSON = partout_import_profile(text, name) else {
            throw PartoutABIError(.decoding)
        }
        defer { free(cJSON) }
        let json = String(cString: cJSON)
        guard let jsonData = json.data(using: .utf8) else {
            throw PartoutABIError(.decoding)
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
            throw PartoutABIError(.decoding)
        }
        defer { free(cJSON) }
        let json = String(cString: cJSON)
        guard let jsonData = json.data(using: .utf8) else {
            throw PartoutABIError(.decoding)
        }
        let tagged = try abiPayload(TaggedModule.self, from: jsonData)
        return tagged.containedModule
    }
}

private extension PartoutImporter {
    func abiPayload<T>(_ type: T.Type, from data: Data) throws -> T where T: Decodable {
        let decoder = JSONDecoder.shared()
        let envelope = try decoder.decode(ABIEnvelope.self, from: data)
        if let code = envelope.code {
            if let payload = envelope.payload {
                throw PartoutABIError(code, payload)
            }
            throw PartoutABIError(code)
        }
        guard let payload = envelope.payload else {
            throw PartoutABIError(.decoding)
        }
        let encoder = JSONEncoder.shared()
        let payloadData = try encoder.encode(payload)
        return try decoder.decode(type, from: payloadData)
    }
}
