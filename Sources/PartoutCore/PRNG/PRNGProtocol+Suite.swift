// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
extension PRNGProtocol {

    /// Generates a random suite of data, usually for testing purposes.
    /// - Parameters:
    ///   - length: The data length.
    ///   - numberOfElements: The number of data objects.
    /// - Returns: An array of `count` data objects of the given `length`.
    public func suite(withDataLength length: Int, numberOfElements: Int) -> [Data] {
        (0..<numberOfElements)
            .reduce(into: []) { dest, _ in
                dest.append(data(length: length))
            }
    }
}
