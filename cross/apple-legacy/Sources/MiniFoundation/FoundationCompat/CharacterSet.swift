// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: MIT

#if MINIF_COMPAT
public struct CharacterSet: Sendable {
    public static let decimalDigits = CharacterSet(charactersIn: "0123456789")
    public static let newlines = CharacterSet(charactersIn: "\r\n")
    public static let urlHostAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:")
    public static let whitespaces = CharacterSet(charactersIn: " ")
    public static let whitespacesAndNewlines = CharacterSet(charactersIn: " \r\n")
    
    private let scalars: Set<Unicode.Scalar>
    private let isInverted: Bool
    
    private init(scalars: Set<Unicode.Scalar>, isInverted: Bool) {
        self.scalars = scalars
        self.isInverted = isInverted
    }
    
    public init(charactersIn chars: String) {
        scalars = Set(chars.unicodeScalars)
        isInverted = false
    }
    
    public func contains(_ ch: Unicode.Scalar) -> Bool {
        !isInverted ? scalars.contains(ch) : !scalars.contains(ch)
    }
    
    public var inverted: Self {
        Self(scalars: scalars, isInverted: !isInverted)
    }
    
    public func union(_ other: CharacterSet) -> CharacterSet {
        switch (isInverted, other.isInverted) {
            
        case (false, false):
            // A ∪ B
            return CharacterSet(scalars: scalars.union(other.scalars), isInverted: false)
            
        case (false, true):
            // A ∪ ∁B  = ∁(B \ A)
            return CharacterSet(scalars: other.scalars.subtracting(scalars), isInverted: true)
            
        case (true, false):
            // ∁A ∪ B = ∁(A \ B)
            return CharacterSet(scalars: scalars.subtracting(other.scalars), isInverted: true)
            
        case (true, true):
            // ∁A ∪ ∁B = ∁(A ∩ B)
            return CharacterSet(scalars: scalars.intersection(other.scalars), isInverted: true)
        }
    }
}   
#endif
