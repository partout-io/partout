// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import _PartoutCore_C
import Partout
import Testing

final class MyDest: LoggerDestination {
    func append(_ level: DebugLog.Level, _ msg: String) {
        print(msg)
        // _ = msg.withCString {
        //     perror($0)
        // }
    }
}

final class DummyFactory: BetterPathStreamFactory {
    func newStream() -> PassthroughStream<Void> {
        PassthroughStream()
    }
}

func tryTCPConnection() async throws {
    var log = PartoutLogger.Builder()
    log.setDestination(MyDest(), for: [.core])
    PartoutLogger.register(log.build())

    pp_log(.global, .core, .fault, ">>> CONNECTING")
    let endpoint = try ExtendedEndpoint("google.com", .init(.tcp, 80))
    let betterPathFactory = DummyFactory()
    let factory = NativeSocketFactory(.global, betterPathFactory: betterPathFactory)
    let observer = factory.linkObserver(to: endpoint)
    let sut = try await observer.waitForActivity(timeout: 5000)
    guard let io = sut.nativeIO else {
        fatalError("Missing .nativeIO")
    }

    let req = "GET / HTTP/1.0\r\n\r\n"
    let reqData = req.data(using: .utf8)!
    pp_log(.global, .core, .fault, ">>> WRITING")
    var offset = 0
    while offset < reqData.count {
        let written = io.write(reqData, offset: offset)
        offset += Int(written)
        print("total=\(reqData.count), written=\(written)")
    }
    pp_log(.global, .core, .fault, ">>> WRITTEN")

    var data = Data()
    let expected = 256
    var buf: [UInt8] = Array(repeating: 0, count: expected)
    while data.count < expected {
        let count = io.read(&buf)
        switch count {
        case 0, PPIOErrorWouldBlock, PPIOErrorNoBufs:
            continue
        default:
            guard count > 0 else {
                fatalError("I/O failure")
            }
        }
        data.append(Data(buf[0..<Int(count)]))
    }
    guard let string = String(data: data, encoding: .utf8) else {
        pp_log(.global, .core, .info, ">>> (hex) \(data.toHex())")
        return
    }
    pp_log(.global, .core, .info, ">>> (utf) \(string)")

    try await Task.sleep(interval: 10)
}

try await tryTCPConnection()
