// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

public final class PartoutImporter: Sendable {
    public init() {}

    public func importModule(from url: URL) throws -> Module? {
        let encoder = JSONEncoder.shared()
        let decoder = JSONDecoder.shared()
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let cJSON = partout_import_module(text) else { return nil }
        defer { free(cJSON) }
        let json = String(cString: cJSON)
        guard let jsonData = json.data(using: .utf8) else { return nil }
        let envelope = try decoder.decode(ABIEnvelope.self, from: jsonData)
        let payloadData = try encoder.encode(envelope.payload)
        guard envelope.code == 0 else {
            let payload = try decoder.decode(ABIErrorPayload.self, from: payloadData)
            if let userInfo = payload.userInfo {
                throw PartoutError(payload.code, userInfo)
            }
            throw PartoutError(payload.code)
        }
        let tagged = try decoder.decode(TaggedModule.self, from: payloadData)
        return tagged.containedModule
    }
}
