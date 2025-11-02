// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

// TODO: #228

extension String {
    public enum CompareOptions {
        case regularExpression
    }

    public init(contentsOf: URL, encoding: String.Encoding) throws {
        fatalError()
    }

    public init(contentsOf: URL, usedEncoding: inout String.Encoding) throws {
        fatalError()
    }

    public init?(data: Data, encoding: String.Encoding) {
        fatalError()
    }

    public init?(cString: UnsafePointer<CChar>, encoding: String.Encoding) {
        fatalError()
    }

    public init(contentsOfFile path: String, encoding: String.Encoding) throws {
        fatalError()
    }

    public init(format: String, _ args: Any...) {
        fatalError()
    }

    public func components(separatedBy separator: String) -> [String] {
        fatalError()
    }

    public func trimmingCharacters(in charset: CharacterSet) -> String {
        fatalError()
    }

    public func cString(using encoding: String.Encoding) -> [CChar] {
        fatalError()
    }

    public func write(to url: URL, atomically: Bool, encoding: String.Encoding) throws {
        fatalError()
    }

    public func enumerateLines(invoking body: @escaping (_ line: String, _ stop: inout Bool) -> Void) {
        fatalError()
    }

    public func replacingOccurrences(of target: String, with replacement: String, options: CompareOptions? = nil) -> String {
        fatalError()
    }

    public func range(of substring: String) -> Range<String.Index>? {
        fatalError()
    }

    public func rangeOfCharacter(from charset: CharacterSet) -> Range<String.Index>? {
        fatalError()
    }
}

extension Substring {
    public func trimmingCharacters(in charset: CharacterSet) -> String {
        String(self).trimmingCharacters(in: charset)
    }
}

extension String {
    public static var newlines: String {
        fatalError()
    }
}
