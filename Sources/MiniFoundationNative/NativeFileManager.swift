// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

extension FileManager: MiniFileManager {
    public var miniTemporaryDirectory: MiniURLProtocol {
        temporaryDirectory
    }

    public func makeTemporaryURL(filename: String) -> MiniURLProtocol {
        temporaryDirectory.appending(component: filename)
    }

    public func miniContentsOfDirectory(at url: MiniURLProtocol) throws -> [MiniURLProtocol] {
        guard let url = url as? URL else {
            assertionFailure("Unexpected URL type")
            return []
        }
        return try contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    public func miniMoveItem(at url: MiniURLProtocol, to: MiniURLProtocol) throws {
        guard let url = url as? URL, let to = to as? URL else {
            assertionFailure("Unexpected URL type")
            return
        }
        try moveItem(at: url, to: to)
    }

    public func miniRemoveItem(at url: MiniURLProtocol) throws {
        guard let url = url as? URL else {
            assertionFailure("Unexpected URL type")
            return
        }
        try removeItem(at: url)
    }

    public func miniAttributesOfItem(atPath path: String) throws -> [MiniFileAttribute: Any] {
        try attributesOfItem(atPath: path)
            .reduce(into: [:]) {
                guard let key = $1.key.toMini else { return } // Ignored attribute
                $0[key] = $1.value
            }
    }
}

private extension FileAttributeKey {
    var toMini: MiniFileAttribute? {
        switch self {
        case .creationDate: return .creationDate
        case .modificationDate: return .modificationDate
        case .size: return .size
        default: return nil
        }
    }
}
