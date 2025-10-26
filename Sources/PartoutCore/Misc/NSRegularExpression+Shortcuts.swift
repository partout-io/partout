// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

extension NSRegularExpression {
    public convenience init(_ pattern: String) {
        do {
            try self.init(pattern: pattern, options: [])
        } catch {
            fatalError("Unable to initialize NSRegularExpression")
        }
    }
}

extension NSRegularExpression {
    public func groups(in string: String) -> [String] {
        var results: [String] = []
        enumerateMatches(in: string, options: [], range: NSRange(location: 0, length: string.count)) { result, _, _ in
            guard let result else {
                return
            }
            for i in 1..<result.numberOfRanges {
                let subrange = result.range(at: i)
                let match = (string as NSString).substring(with: subrange)
                results.append(match)
            }
        }
        return results
    }
}
