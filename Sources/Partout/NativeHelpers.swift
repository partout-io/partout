// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

internal import _PartoutCore_C

final class NativeCompletion {
    static let callback: pp_completion = { ctx, code in
        guard let ctx else { return }
        let box = Unmanaged<NativeCompletion>.fromOpaque(ctx).takeRetainedValue()
        guard code == 0 else {
            box.continuation.resume(throwing: NativeError(code: code))
            return
        }
        box.continuation.resume()
    }

    let continuation: CheckedContinuation<Void, Error>

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }
}

struct NativeError: Error, CustomDebugStringConvertible, Sendable {
    let code: Int32

    var debugDescription: String {
        "Native C layer failed with code \(code)"
    }
}
