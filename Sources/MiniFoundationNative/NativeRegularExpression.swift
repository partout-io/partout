// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

public final class NativeRegularExpression: MiniRegularExpression {
    private let impl: NSRegularExpression

    public init(_ pattern: String) {
        do {
            impl = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            fatalError("Invalid pattern: \(pattern), \(error)")
        }
    }

    public func enumerateMatches(in string: String, using block: @escaping (String) -> Void) {
        impl.enumerateMatches(in: string, range: NSRange(location: 0, length: string.count)) { result, _, _ in
            guard let result else { return }
            let match = (string as NSString).substring(with: result.range)
            block(match)
        }
    }
}
