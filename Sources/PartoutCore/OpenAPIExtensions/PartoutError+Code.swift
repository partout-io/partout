// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
public func == (lhs: String, rhs: PartoutError.Code) -> Bool {
    PartoutError.Code(rawValue: lhs) == rhs
}

public func == (lhs: PartoutError.Code, rhs: String) -> Bool {
    rhs == lhs
}

public func == (lhs: String?, rhs: PartoutError.Code) -> Bool {
    lhs.map { $0 == rhs } ?? false
}

public func == (lhs: PartoutError.Code, rhs: String?) -> Bool {
    rhs == lhs
}

public func ~= (pattern: PartoutError.Code, value: String) -> Bool {
    value == pattern
}

public func ~= (pattern: PartoutError.Code, value: String?) -> Bool {
    value == pattern
}

extension ABIErrorPayload {
    public init(_ error: Error) {
        guard let partoutError = error as? PartoutError else {
            self.init(
                code: .unhandled,
                userInfo: try? JSON(["localizedDescription": error.localizedDescription])
            )
            return
        }
        guard let userInfo = partoutError.userInfo as? Encodable else {
            self.init(code: partoutError.code, userInfo: nil)
            return
        }
        self.init(code: partoutError.code, userInfo: try? JSON(encodable: userInfo))
    }
}
