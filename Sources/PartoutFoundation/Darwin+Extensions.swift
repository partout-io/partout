// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if canImport(Darwin)

extension Data {
    public init(bytesNoCopy: UnsafeMutablePointer<UInt8>, count: Int) {
        self.init(bytesNoCopy: bytesNoCopy, count: count, deallocator: .none)
    }

    public init(bytesNoCopy: UnsafeMutablePointer<UInt8>, count: Int, customDeallocator: @escaping () -> Void) {
        self.init(bytesNoCopy: bytesNoCopy, count: count, deallocator: .custom { _, _ in
            customDeallocator()
        })
    }
}

extension FileManager {
    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}

extension NotificationCenter {
    public func post(name: Notification.Name) {
        post(name: name, object: nil)
    }

    public func addObserver(forName name: Notification.Name, using block: @escaping () -> Void) {
        addObserver(forName: name, object: nil, queue: nil, using: { _ in
            block()
        })
    }
}

extension RegularExpression {
    public convenience init(_ pattern: String) {
        do {
            try self.init(pattern: pattern, options: [])
        } catch {
            fatalError("Unable to initialize RegularExpression")
        }
    }

    public func groups(in string: String) -> [String] {
        var results: [String] = []
        enumerateMatches(in: string, range: NSRange(location: 0, length: string.count)) { result, _, _ in
            guard let result else { return }
            for i in 1..<result.numberOfRanges {
                let subrange = result.range(at: i)
                let match = (string as NSString).substring(with: subrange)
                results.append(match)
            }
        }
        return results
    }

    public func enumerateMatches(in string: String, using block: @escaping (String) -> Void) {
        enumerateMatches(in: string, range: NSRange(location: 0, length: string.count)) { result, _, _ in
            guard let result else { return }
            let match = (string as NSString).substring(with: result.range)
            block(match)
        }
    }

    public func replacingMatches(in string: String, withTemplate template: String) -> String {
        let replaced = NSMutableString(string: string)
        replaceMatches(
            in: replaced,
            range: NSRange(location: 0, length: replaced.length),
            withTemplate: template
        )
        return replaced as String
    }
}

#else

// TODO: #228

extension Data {
    public init(bytesNoCopy: UnsafeMutablePointer<UInt8>, count: Int) {
        fatalError()
    }

    public init(bytesNoCopy: UnsafeMutablePointer<UInt8>, count: Int, customDeallocator: @escaping () -> Void) {
        fatalError()
    }
}

extension FileManager {
    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        fatalError()
    }
}

extension NotificationCenter {
    public func post(name: Notification.Name) {
        fatalError()
    }

    public func addObserver(forName: Notification.Name, using block: @escaping () -> Void) {
        fatalError()
    }
}

extension RegularExpression {
    public convenience init(pattern: String) {
        fatalError()
    }

    public convenience init(_ pattern: String) {
        self.init(pattern: pattern)
    }

    public func groups(in string: String) -> [String] {
        fatalError()
    }

    public func enumerateMatches(in string: String, using block: @escaping (String) -> Void) {
        fatalError()
    }

    public func replacingMatches(in string: String, withTemplate template: String) -> String {
        fatalError()
    }
}

#endif
