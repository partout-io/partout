// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Dispatch

/// The context of a log message.
public struct PartoutLoggerContext: Sendable {
    public static let global = PartoutLoggerContext()

    public var logger: PartoutLogger {
        .default
    }

    public let profileId: Profile.ID?

    private init() {
        profileId = nil
    }

    public init(_ profileId: Profile.ID) {
        self.profileId = profileId
    }
}

/// The common interface of a logger.
public protocol PartoutLoggerProtocol {
    var logsAddresses: Bool { get }

    var logsModules: Bool { get }

    var logsRawBytes: Bool { get }

    var assertsMissingLoggingCategory: Bool { get }
}

/// The global entity in charge of all the logging. Use a ``Builder`` to create one.
public final class PartoutLogger: PartoutLoggerProtocol, Sendable {
    public typealias PrintFunction = @Sendable (PartoutLoggerContext, String) -> String

    private let destinations: [LoggerCategory: LoggerDestination]

    private let localLogger: LocalLogger?

    /// Enables logging of public network addresses (defaults to false).
    public let logsAddresses: Bool

    /// Enables logging of modules (defaults to false).
    public let logsModules: Bool

    /// Enables logging of raw bytes (default to false).
    public let logsRawBytes: Bool

    /// Throws an assertion if logging to an unregistered category.
    public let assertsMissingLoggingCategory: Bool

    /// The print function.
    public let willPrint: PrintFunction

    fileprivate init(
        destinations: [LoggerCategory: LoggerDestination],
        localLogger: LocalLogger?,
        logsAddresses: Bool,
        logsModules: Bool,
        logsRawBytes: Bool,
        assertsMissingLoggingCategory: Bool,
        willPrint: @escaping PrintFunction
    ) {
        self.destinations = destinations
        self.localLogger = localLogger
        self.logsAddresses = logsAddresses
        self.logsModules = logsModules
        self.logsRawBytes = logsRawBytes
        self.assertsMissingLoggingCategory = assertsMissingLoggingCategory
        self.willPrint = willPrint
    }

    deinit {
        // Do NOT use pp_log here, it might be self!
        NSLog("Partout: Deinit PartoutLogger")
    }

    public func destination(for category: LoggerCategory) -> LoggerDestination? {
        destinations[category]
    }
}

// MARK: Global

extension PartoutLogger {
    private static let queue = DispatchQueue(label: "PartoutLogger")

    nonisolated(unsafe)
    private static var globalLogger = PartoutLogger.Builder().build()

    public static var `default`: PartoutLogger {
        queue.sync {
            globalLogger
        }
    }
}

extension PartoutLogger {
    /// Registers a new ``PartoutLogger`` globally.
    public static func register(_ logger: PartoutLogger) {
        queue.sync {
            NSLog("Partout: Set global logger")
            globalLogger = logger
        }
    }
}

// MARK: - LocalLogger

extension PartoutLogger {
    public var hasLocalLogger: Bool {
        localLogger != nil
    }

    public var localLoggerPath: String? {
        localLogger?.path
    }

    public func appendLog(_ level: DebugLog.Level, message: String) {
        localLogger?.append(level, message: message)
    }

    public func currentLogLines(sinceLast: TimeInterval, maxLevel: DebugLog.Level) -> [DebugLog.Line] {
        localLogger?.currentLines(sinceLast: sinceLast, maxLevel: maxLevel) ?? []
    }

    public func flushLog() {
        localLogger?.save()
    }
}

// MARK: - Builder

extension PartoutLogger {

    /// The way to create a ``PartoutLogger``.
    public struct Builder: PartoutLoggerProtocol, Sendable {
        private var destinations: [LoggerCategory: LoggerDestination] = [:]

        public var localLogger: LocalLogger?

        public var logsAddresses = false

        public var logsModules = false

        public var logsRawBytes = false

        public var assertsMissingLoggingCategory = false

        public var willPrint: PrintFunction = { $1 }

        public init() {
        }

        public mutating func setDestination(_ destination: LoggerDestination, for categories: [LoggerCategory]) {
            categories.forEach {
                destinations[$0] = destination
            }
        }

        /// Enables the local logger in addition to OSLog. Only use for troubleshooting.
        public mutating func setLocalLogger(
            path: String,
            options: LocalLogger.Options,
            mapper: @escaping (DebugLog.Line) -> String
        ) {
            localLogger = LocalLogger(path: path, options: options, mapper: mapper)
        }

        public func build() -> PartoutLogger {
            PartoutLogger(
                destinations: destinations,
                localLogger: localLogger,
                logsAddresses: logsAddresses,
                logsModules: logsModules,
                logsRawBytes: logsRawBytes,
                assertsMissingLoggingCategory: assertsMissingLoggingCategory,
                willPrint: willPrint
            )
        }
    }
}
