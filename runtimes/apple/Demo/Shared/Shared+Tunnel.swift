// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutRuntime

extension NEProtocolDecoder where Self == ProviderNEProtocolCoder {
    static var shared: Self {
        Demo.neProtocolCoder
    }
}
