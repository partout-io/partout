// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import Partout

enum Demo {
}

// MARK: Constants

extension Demo {
    private static let appConfig = BundleConfiguration(.main, key: "AppConfig")!

    static var teamIdentifier: String {
        appConfig.value(forKey: "team_id")!
    }

    static var appIdentifier: String {
        appConfig.value(forKey: "app_id")!
    }

    static var appGroupIdentifier: String {
        appConfig.value(forKey: "group_id")!
    }

    static var tunnelBundleIdentifier: String {
        appConfig.value(forKey: "tunnel_id")!
    }

    static var cachesURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            fatalError("Unable to access App Group container")
        }
        return url.appending(components: "Library", "Caches")
    }

    static func moduleURL(for name: String) -> URL {
        do {
            let url = cachesURL.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            fatalError("No access to caches directory")
        }
    }
}

extension Demo {
    enum Log {
        static let tunnelURL = Demo.cachesURL.appending(component: "tunnel.log")

        static let maxLevel: DebugLog.Level = .info

        static let maxSize: UInt64 = 10000

        static let maxBufferedLines = 1000

        static let saveInterval = 60000

        static func formattedLine(_ line: DebugLog.Line) -> String {
            let ts = line.timestamp
                .formatted(
                    .dateTime
                        .hour(.twoDigits(amPM: .omitted))
                        .minute()
                        .second()
                )

            return "\(ts) - \(line.message)"
        }
    }
}

// MARK: - Implementations

extension Demo {
    static var neProtocolCoder: KeychainNEProtocolCoder {
        KeychainNEProtocolCoder(
            .global,
            tunnelBundleIdentifier: Demo.tunnelBundleIdentifier,
            registry: .shared,
            coder: CodableProfileCoder(),
            keychain: AppleKeychain(.global, group: "\(teamIdentifier).\(appGroupIdentifier)")
        )
    }

    static let tunnelEnvironment: UserDefaultsEnvironment = {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            fatalError("Not entitled to App Group: \(appGroupIdentifier)")
        }
        return UserDefaultsEnvironment(profileId: nil, defaults: defaults)
    }()
}
