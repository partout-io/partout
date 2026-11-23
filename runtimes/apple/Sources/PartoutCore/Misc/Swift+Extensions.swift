// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension Collection {
    public func first<T>(ofType type: T.Type) -> T? {
        first { $0 is T } as? T
    }

    public func unique() -> [Element] where Element: Equatable {
        reduce(into: []) {
            guard !$0.contains($1) else {
                return
            }
            $0.append($1)
        }
    }
}

extension Array where Element == CChar {
    public var string: String {
        withUnsafeBytes {
            let buf = $0.bindMemory(to: CChar.self)
            return String(cString: buf.baseAddress!)
        }
    }
}
