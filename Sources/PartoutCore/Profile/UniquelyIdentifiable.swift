// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Any entity that can be identified with an UniqueID.
public protocol UniquelyIdentifiable {
    var id: UniqueID { get }
}
