// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public final class PartoutImporter: Sendable {
    public init() {}

    public func importModule<M>(_ type: M.Type, url: URL) throws -> M? where M: Decodable {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let cJSON = partout_import_module(text) else { return nil }
        defer { free(cJSON) }
        let json = String(cString: cJSON)
        guard let jsonData = json.data(using: .utf8) else { return nil }
        let envelope = try JSONDecoder.shared().decode(ABIEnvelope.self, from: jsonData)
        let payloadData = try JSONEncoder.shared().encode(envelope.payload)
        if envelope.code != 0 {
            let payload = try JSONDecoder.shared().decode(ABIErrorPayload.self, from: payloadData)
            if let userInfo = payload.userInfo {
                throw PartoutError(payload.code, userInfo)
            }
            throw PartoutError(payload.code)
        }
        let tagged = try JSONDecoder.shared().decode(TaggedModule.self, from: payloadData)
        return tagged.containedModule as? M
    }
}
