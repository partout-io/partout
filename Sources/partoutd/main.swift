// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Partout
import Partout_C

guard CommandLine.arguments.count > 1 else {
    print("Configuration file required")
    throw PartoutError(.notFound)
}

let profilePath = CommandLine.arguments[1]
print("Starting with profile at: \(profilePath)")
let profile = try String(contentsOfFile: profilePath, encoding: .utf8)
let cacheDir = "."

// Initialize library
let ctx = cacheDir.withCString { cCacheDir in
    var args = partout_daemon_init_args()
    args.cache_dir = cCacheDir
    return partout_init(cArgs: &args)
}

// Start daemon
try profile.withCString { cProfile in
    var args = partout_daemon_start_args()
    args.profile = cProfile
    guard partout_daemon_start(cCtx: ctx, cArgs: &args) == 0 else {
        throw PartoutError(.linkNotActive)
    }
}
print("Daemon successfully started")

// Keep running
let semaphore = DispatchSemaphore(value: 0)
_ = semaphore.wait(timeout: .distantFuture)
