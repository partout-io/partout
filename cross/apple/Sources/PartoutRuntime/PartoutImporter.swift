// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public final class PartoutImporter: Sendable {
    public init() {}

    public func importProfile(from text: String) throws -> Profile? {
        guard let cJSON = partout_import_profile(text, nil) else { return nil }
        defer { free(cJSON) }
        let json = String(cString: cJSON)
        guard let jsonData = json.data(using: .utf8) else { return nil }

        let tagged = try abiPayload(TaggedProfile.self, from: jsonData)
        return try tagged.asProfile()
    }

    public func importModule(from url: URL) throws -> Module? {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try importModule(from: text)
    }

    public func importModule(from text: String) throws -> Module? {
        guard let cJSON = partout_import_module(text) else { return nil }
        defer { free(cJSON) }
        let json = String(cString: cJSON)
        guard let jsonData = json.data(using: .utf8) else { return nil }

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
                throw PartoutError(code, payload)
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
