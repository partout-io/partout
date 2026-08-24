// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutRuntime

extension WireGuard {
    static var demoModule: WireGuardModule? {
        do {
            guard let url = Constants.demoURL else { return nil }
            guard let module = try PartoutImporter()
                .importModule(from: url) as? WireGuardModule else { return nil }
            return module
        } catch {
            fatalError("Unable to build: \(error)")
        }
    }
}

private enum Constants {
    static let demoURL = Bundle.main.url(forResource: "Files/test-sample", withExtension: "wg")
}
