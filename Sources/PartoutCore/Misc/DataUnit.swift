// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Helps expressing integers in shortened data units (e.g. kB).
@frozen
public enum DataUnit: UInt {
    case byte = 1

    case kilobyte = 1024

    case megabyte = 1048576

    case gigabyte = 1073741824
}

extension DataUnit: CustomStringConvertible {
    public var description: String {
        switch self {
        case .byte:
            return "B"

        case .kilobyte:
            return "kB"

        case .megabyte:
            return "MB"

        case .gigabyte:
            return "GB"
        }
    }

    fileprivate static let descendingCases: [DataUnit] = [
        .gigabyte,
        .megabyte,
        .kilobyte,
        .byte
    ]
}

/// Supports being expressed in data units.
public protocol DataUnitRepresentable {

    /// Returns `self` expressed in human-readable data units.
    var descriptionAsDataUnit: String { get }
}

// MARK: - Extensions

extension UInt: DataUnitRepresentable {
    public var descriptionAsDataUnit: String {
        if self == 0 {
            return "0B"
        }
        if self < DataUnit.kilobyte.rawValue {
            return "\(self)B"
        }
        for u in DataUnit.descendingCases {
            if self >= u.boundary {
                if !u.showsDecimals {
                    return "\(self / u.rawValue)\(u)"
                }
                let count = Double(self) / Double(u.rawValue)
                return String(format: "%.2f%@", count, u.description)
            }
        }
        fatalError("Number is negative")
    }
}

extension Int: DataUnitRepresentable {
    public var descriptionAsDataUnit: String {
        return UInt(self).descriptionAsDataUnit
    }
}

// MARK: - Helpers

private extension DataUnit {
    var showsDecimals: Bool {
        switch self {
        case .byte, .kilobyte:
            return false

        case .megabyte, .gigabyte:
            return true
        }
    }

    var boundary: UInt {
        return UInt(0.1 * Double(rawValue))
    }
}
