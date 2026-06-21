// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

struct ABIErrorPayload: Encodable {
    let code: PartoutErrorCode
    let userInfo: JSON?

    init(_ error: Error) {
        guard let partoutError = error as? PartoutError else {
            code = .unhandled
            userInfo = try? JSON(["localizedDescription": error.localizedDescription])
            return
        }
        code = partoutError.code
        guard let userInfo = partoutError.userInfo as? Encodable else {
            userInfo = nil
            return
        }
        self.userInfo = try? JSON(encodable: userInfo)
    }
}
