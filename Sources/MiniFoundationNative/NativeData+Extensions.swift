// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

import Foundation
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

extension Data {
    public init(bytesNoCopy: UnsafeMutablePointer<UInt8>, count: Int) {
        self.init(bytesNoCopy: bytesNoCopy, count: count, deallocator: .none)
    }

    public init(bytesNoCopy: UnsafeMutablePointer<UInt8>, count: Int, customDeallocator: @escaping () -> Void) {
        self.init(bytesNoCopy: bytesNoCopy, count: count, deallocator: .custom { _, _ in
            customDeallocator()
        })
    }

    public func subdata(offset: Int, count: Int) -> Data {
        subdata(in: offset..<(offset + count))
    }

    public mutating func shrink(to newCount: Int) {
        precondition(newCount <= count, "Shrink must be to a smaller size")
        guard newCount < count else { return }
        count = newCount
    }

    public func write(toFile path: String) throws {
        let url = URL(fileURLWithPath: path)
        try write(to: url, options: .atomic)
    }
}
