// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Extensible error type thrown by the library.
public struct PartoutError: Error {
    private static let subCodeKey = "subCode"

    public let code: Code

    public let reason: Error?

    public let userInfo: Sendable?

    /// Portable JSON context received from or sent to the native runtime.
    public var payload: JSON? { userInfo as? JSON }

    public init(_ code: Code, payload: JSON?, reason: Error? = nil) {
        self.code = code
        self.userInfo = payload
        self.reason = reason
    }

    public init?(rawValue: String) {
        guard let extendedCode = PartoutErrorExtendedCode(rawValue: rawValue) else { return nil }
        self.init(extendedCode.code, payload: extendedCode.subCode.map {
            [Self.subCodeKey: .string($0)]
        })
    }

    public var subCode: String? {
        payload?[Self.subCodeKey]?.stringValue
    }

    public var extendedCode: PartoutErrorExtendedCode {
        PartoutErrorExtendedCode(code: code, subCode: subCode)
    }

    public var rawValue: String { extendedCode.rawValue }

    public init(codeForOpenVPN code: OpenVPNErrorCode) {
        self.init(.openVPN, payload: [Self.subCodeKey: .string(code.rawValue)])
    }

    public init(codeForWireGuard code: WireGuardErrorCode) {
        self.init(.wireGuard, payload: [Self.subCodeKey: .string(code.rawValue)])
    }

    public init(_ code: Code) {
        self.code = code
        reason = nil
        userInfo = nil
    }

    public init(_ code: Code, _ reason: Error) {
        self.code = code
        self.reason = reason
        userInfo = nil
    }

    public init(_ code: Code, _ userInfo: Sendable, _ reason: Error? = nil) {
        self.code = code
        self.reason = reason
        self.userInfo = userInfo
    }

    public init(_ error: Error) {
        switch error {
        case let error as Self:
            self = error
        default:
            self = Self.unhandled(reason: error)
        }
    }
}

extension PartoutError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.code == rhs.code
    }
}

extension Error {
    public var partoutErrorCode: PartoutError.Code {
        switch self {
        case let pe as PartoutError:
            return pe.code
        default:
            return .unhandled
        }
    }
}

// MARK: - Description

extension PartoutError: CustomDebugStringConvertible {
    public var debugDescription: String {
        var desc: [String] = ["PartoutError.\(code.rawValue)"]
        if let userInfo {
            desc.append("userInfo=\(String(describing: userInfo))")
        }
        if let reason {
            desc.append("reason=\(reason) (\(reason.localizedDescription))")
        }
        return "{\(desc.joined(separator: ", "))}"
    }
}
