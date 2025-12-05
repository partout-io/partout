// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: MIT

internal import _MiniFoundationCore_C
#if !MINI_FOUNDATION_MONOLITH
import MiniFoundationCore
#endif

extension Compat {
    public final class RegularExpression: MiniRegularExpression {
        private let pattern: String

        public init(_ pattern: String) {
            self.pattern = pattern
        }

        public func enumerateMatches(in string: String, using block: @escaping (String) -> Void) {
            guard let result = minif_rx_matches(pattern, string) else { return }
            defer { minif_rx_result_free(result) }
            let count = minif_rx_result_get_items_count(result)
            for i in 0..<count {
                let match = minif_rx_result_get_item(result, Int32(i))
                let str = minif_rx_match_get_token(match)
                block(String(cString: str))
            }
        }
    }
}
