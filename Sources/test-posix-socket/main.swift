// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutOSPortable
import PartoutCore
import Testing

final class MyDest: LoggerDestination {
    func append(_ level: DebugLog.Level, _ msg: String) {
        print(msg)
        // _ = msg.withCString {
        //     perror($0)
        // }
    }
}

func tryTCPConnection() async throws {
    var log = PartoutLogger.Builder()
    log.setDestination(MyDest(), for: [.core])
    PartoutLogger.register(log.build())

    pp_log(.global, .core, .fault, ">>> CONNECTING")
    let endpoint = try ExtendedEndpoint("vps", .init(.tcp, 80))
    let observer = POSIXSocketObserver(
        .global,
        endpoint: endpoint,
        betterPathBlock: {
            PassthroughStream()
        }
    )
    let sut = try await observer.waitForActivity(timeout: 5000)

    let req = "GET / HTTP/1.0\r\n\r\n"
    let reqData = req.data(using: .utf8)!
    pp_log(.global, .core, .fault, ">>> WRITING")
    try await sut.writePackets([reqData])
    pp_log(.global, .core, .fault, ">>> WRITTEN")

    sut.setReadHandler { packets, error in
        if let error {
            pp_log(.global, .core, .info, ">>> (error) \(error)")
            return
        }
        packets?.forEach {
            guard let string = String(data: $0, encoding: .utf8) else {
                pp_log(.global, .core, .info, ">>> (hex) \($0.toHex())")
                return
            }
            pp_log(.global, .core, .info, ">>> (utf) \(string)")
        }
    }

    try await Task.sleep(interval: 10)
}

try await tryTCPConnection()
