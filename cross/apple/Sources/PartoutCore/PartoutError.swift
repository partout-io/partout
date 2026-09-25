// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// ABI errors.
public struct PartoutABIError: Error {
    public let code: PartoutErrorCode
    public let payload: JSON?

    public init(_ code: PartoutErrorCode, _ payload: JSON? = nil) {
        self.code = code
        self.payload = payload
    }

    public init?(rawValue: String) {
        guard let extendedCode = PartoutErrorExtendedCode(rawValue: rawValue) else { return nil }
        self.init(extendedCode.code, extendedCode.subCode.map { ["subCode": .string($0)] })
    }

    public var subCode: String? {
        payload?["subCode"]?.stringValue
    }

    public var extendedCode: PartoutErrorExtendedCode {
        PartoutErrorExtendedCode(code: code, subCode: subCode)
    }

    public var rawValue: String { extendedCode.rawValue }

    public init(codeForOpenVPN code: OpenVPNErrorCode) {
        self.init(.openVPN, ["subCode": .string(code.rawValue)])
    }

    public init(codeForWireGuard code: WireGuardErrorCode) {
        self.init(.wireGuard, ["subCode": .string(code.rawValue)])
    }
}

/// Extensible error type thrown by the library.
public struct PartoutError: Error {
    public let code: Code

    public let reason: Error?

    public let userInfo: Sendable?

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
        case let error as PartoutABIError:
            code = error.code
            userInfo = error.payload
            reason = nil
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
        case let error as PartoutABIError:
            return error.code
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
