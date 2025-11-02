// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension TimeInterval {
    public var asTimeString: String {
        var ticks = Int(self)
        let hours = ticks / 3600
        ticks %= 3600
        let minutes = ticks / 60
        let seconds = ticks % 60

        let comps = [(hours, "h"), (minutes, "m"), (seconds, "s")]
            .filter { $0.0 > 0 }
            .map { "\($0.0)\($0.1)" }
        guard !comps.isEmpty else {
            return "0s"
        }
        return comps.joined()
    }
}
