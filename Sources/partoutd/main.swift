// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Partout

guard CommandLine.arguments.count > 1 else {
    print("Configuration file required")
    throw PartoutError(.notFound)
}

let profilePath = CommandLine.arguments[1]
print("Starting with profile at: \(profilePath)")
let cProfile = try String(contentsOfFile: profilePath, encoding: .utf8)

let ctx = partout_initialize(cCacheDir: ".")
guard partout_daemon_start(cCtx: ctx, cProfile: cProfile) == 0 else {
    throw PartoutError(.linkNotActive)
}
print("Daemon successfully started")

// Keep running
let semaphore = DispatchSemaphore(value: 0)
_ = semaphore.wait(timeout: .distantFuture)
