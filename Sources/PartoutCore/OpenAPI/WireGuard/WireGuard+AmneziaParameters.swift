// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension WireGuard {

    /// The AmneziaWG obfuscation parameters.
    public struct AmneziaParameters: BuildableType, Hashable, Codable, Sendable {

        public let jc: UInt16?

        public let jmin: UInt16?

        public let jmax: UInt16?

        public let s1: UInt16?

        public let s2: UInt16?

        public let s3: UInt16?

        public let s4: UInt16?

        public let h1: String?

        public let h2: String?

        public let h3: String?

        public let h4: String?

        public let i1: String?

        public let i2: String?

        public let i3: String?

        public let i4: String?

        public let i5: String?

        public init(
            jc: UInt16?,
            jmin: UInt16?,
            jmax: UInt16?,
            s1: UInt16?,
            s2: UInt16?,
            s3: UInt16?,
            s4: UInt16?,
            h1: String?,
            h2: String?,
            h3: String?,
            h4: String?,
            i1: String?,
            i2: String?,
            i3: String?,
            i4: String?,
            i5: String?
        ) {
            self.jc = jc
            self.jmin = jmin
            self.jmax = jmax
            self.s1 = s1
            self.s2 = s2
            self.s3 = s3
            self.s4 = s4
            self.h1 = h1
            self.h2 = h2
            self.h3 = h3
            self.h4 = h4
            self.i1 = i1
            self.i2 = i2
            self.i3 = i3
            self.i4 = i4
            self.i5 = i5
        }

        public func builder() -> Builder {
            var copy = Builder()
            copy.jc = jc
            copy.jmin = jmin
            copy.jmax = jmax
            copy.s1 = s1
            copy.s2 = s2
            copy.s3 = s3
            copy.s4 = s4
            copy.h1 = h1
            copy.h2 = h2
            copy.h3 = h3
            copy.h4 = h4
            copy.i1 = i1
            copy.i2 = i2
            copy.i3 = i3
            copy.i4 = i4
            copy.i5 = i5
            return copy
        }
    }
}

extension WireGuard.AmneziaParameters {
    public struct Builder: BuilderType, Hashable, Sendable {
        public var jc: UInt16?

        public var jmin: UInt16?

        public var jmax: UInt16?

        public var s1: UInt16?

        public var s2: UInt16?

        public var s3: UInt16?

        public var s4: UInt16?

        public var h1: String?

        public var h2: String?

        public var h3: String?

        public var h4: String?

        public var i1: String?

        public var i2: String?

        public var i3: String?

        public var i4: String?

        public var i5: String?

        public init() {
        }

        public func build() throws -> WireGuard.AmneziaParameters {
            WireGuard.AmneziaParameters(
                jc: jc,
                jmin: jmin,
                jmax: jmax,
                s1: s1,
                s2: s2,
                s3: s3,
                s4: s4,
                h1: h1,
                h2: h2,
                h3: h3,
                h4: h4,
                i1: i1,
                i2: i2,
                i3: i3,
                i4: i4,
                i5: i5
            )
        }
    }
}
