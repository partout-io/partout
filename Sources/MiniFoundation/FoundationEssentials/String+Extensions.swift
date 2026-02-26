// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension String {
    public func strippingWhitespaces() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: .whitespaces, with: " ")
    }

    public func replacingOccurrences(of charset: CharacterSet, with replacement: String) -> String {
        var out = String()
        out.reserveCapacity(self.count)
        var shouldReplace = false
        for char in self {
            // A Character can be made of multiple scalars.
            // If *any* scalar is in the set → replace.
            shouldReplace = false
            for scalar in char.unicodeScalars {
                if charset.contains(scalar) {
                    shouldReplace = true
                    break
                }
            }
            if shouldReplace {
                out.append(replacement)
            } else {
                out.append(char)
            }
        }
        return out
    }
}

// MARK: - Other

extension String {
    public func hexData() -> Data? {
        let len = self.count
        guard len % 2 == 0 else { return nil } // must be even length
        var bytes = [UInt8]()
        bytes.reserveCapacity(len / 2)
        var index = self.startIndex
        for _ in 0..<(len / 2) {
            let nextIndex = self.index(index, offsetBy: 2)
            let byteString = self[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        return Data(bytes)
    }
}

extension StringProtocol where Self == String {
    public static var newlines: String { "\n" }
}
