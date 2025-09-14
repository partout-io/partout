// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Partout
import SwiftUI

@main
struct DemoApp: App {
    init() {
        var loggerBuilder = PartoutLogger.Builder()
        loggerBuilder.logsModules = true
        loggerBuilder.setLocalLogger(
            url: Demo.Log.appURL,
            options: .init(
                maxLevel: Demo.Log.maxLevel,
                maxSize: Demo.Log.maxSize,
                maxBufferedLines: Demo.Log.maxBufferedLines
            ),
            mapper: Demo.Log.formattedLine
        )
        PartoutLogger.register(loggerBuilder.build())
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
        }
    }
}
