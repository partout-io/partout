// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

extension WireGuard {
    static var demoModule: WireGuardModule? {
        do {
            guard let url = Constants.demoURL else { return nil }
            return try Demo.parseModule(WireGuardModule.self, url: url)
        } catch {
            fatalError("Unable to build: \(error)")
        }
    }
}

private enum Constants {
    static let demoURL = Bundle.main.url(forResource: "Files/test-sample", withExtension: "wg")
}
