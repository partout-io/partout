// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_STATIC
import PartoutCore
#endif

extension LoggerCategory {
    public static let api = Self(rawValue: "api")
}

extension PartoutError.Code {
    public enum API {

        /// The API engine encountered an error.
        public static let engineError = PartoutError.Code("API.engineError")
    }
}
