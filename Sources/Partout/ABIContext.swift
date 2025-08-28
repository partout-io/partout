// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

final class ABIContext {
    let registry: Registry

    var daemon: SimpleConnectionDaemon?

    init(registry: Registry) {
        self.registry = registry
    }
}

extension ABIContext {
    static func fromOpaque(_ raw: UnsafeMutableRawPointer) -> ABIContext {
        Unmanaged.fromOpaque(raw).takeRetainedValue()
    }

    var toOpaque: UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }
}
