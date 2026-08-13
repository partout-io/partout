// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

extension NEProtocolDecoder where Self == KeychainNEProtocolCoder {
    static var shared: Self {
        Demo.neProtocolCoder
    }
}
