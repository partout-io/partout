// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Mappable to ``PartoutError``.
public protocol PartoutErrorMappable {
    var asPartoutError: PartoutError { get }
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
        do {
            throw error
        } catch let error as Self {
            self = error
        } catch let error as PartoutErrorMappable {
            self = error.asPartoutError
        }
        // anything else
        catch {
            self = Self.unhandled(reason: error)
        }
    }
}

extension PartoutError {
    public struct Code: RawRepresentable, Hashable, Codable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ string: String) {
            rawValue = string
        }
    }
}

extension PartoutError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.code == rhs.code
    }
}

// MARK: - Description

extension PartoutError: CustomDebugStringConvertible {
    public var debugDescription: String {
        let desc = [code.rawValue, userInfo.map(String.init(describing:)), reason?.localizedDescription]
            .compactMap { $0 }
            .joined(separator: ", ")

        return "[PartoutError.\(desc)]"
    }
}
