// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

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
