// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

extension Data {
    public init(contentsOfFile path: String) throws {
        let buf = try FileBuffer(contentsOfFile: path)
        self.init(buf.bytes)
    }
}
