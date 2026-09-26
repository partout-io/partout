// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension PartoutErrorPair: RawRepresentable {
    public init?(rawValue: String) {
        let components = rawValue.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = components.first, let code = PartoutErrorCode(rawValue: String(first)) else { return nil }
        if components.count == 2 {
            guard !components[1].isEmpty else { return nil }
            self.init(code: code, subCode: String(components[1]))
        } else {
            self.init(code: code)
        }
    }

    public var rawValue: String {
        subCode.map { "\(code.rawValue).\($0)" } ?? code.rawValue
    }
}
