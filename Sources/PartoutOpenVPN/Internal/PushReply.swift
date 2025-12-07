// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

struct PushReply {
    private let original: String

    let options: OpenVPN.Configuration

    fileprivate init(original: String, options: OpenVPN.Configuration) {
        self.original = original
        self.options = options
    }
}

extension PushReply: CustomStringConvertible {
    var description: String {
        do {
            // Drop leading "^" to match containment
            let containing = String(OpenVPN.Option.authToken.rawValue.dropFirst())
            let rx = try Regex(containing)
            return original.replacing(rx, with: "auth-token")
        } catch {
            return original
        }
    }
}

extension StandardOpenVPNParser {
    private static let prefix = "PUSH_REPLY,"

    func pushReply(with message: String) throws -> PushReply? {
        guard message.hasPrefix(Self.prefix) else {
            return nil
        }
        guard let prefixIndex = message.range(of: Self.prefix)?.lowerBound else {
            return nil
        }
        guard !message.contains("push-continuation 2") else {
            throw StandardOpenVPNParserError.continuationPushReply
        }
        let original = String(message[prefixIndex...])
        let lines = original.components(separatedBy: ",")
        let options = try parsed(fromLines: lines).configuration

        return PushReply(original: original, options: options)
    }
}
