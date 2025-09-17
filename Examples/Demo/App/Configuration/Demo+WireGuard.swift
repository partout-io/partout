// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Partout

extension WireGuard {
    static var demoModule: WireGuardModule? {
        do {
            guard let url = Constants.demoURL else {
                return nil
            }
            let wg = try String(contentsOf: url)
            let builder = try StandardWireGuardParser().configuration(from: wg).builder()
            let module = WireGuardModule.Builder(configurationBuilder: builder)
            return try module.tryBuild()
        } catch {
            fatalError("Unable to build: \(error)")
        }
    }
}

private enum Constants {
    static let demoURL = Bundle.main.url(forResource: "Files/test-sample", withExtension: "wg")
}
