// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

extension OpenVPNSessionV3 {
    enum SessionState {
        case stopped(IdleContext)
        case active(ActivePhase, ActiveContext)
    }

    enum ActivePhase {
        case starting
        case started
        case stopping
    }

    struct IdleContext {
        var withLocalOptions: Bool
    }

    struct ActiveContext {
        private let dataLink: DataLink
        var withLocalOptions: Bool
        var linkMetadata: LinkMetadata
        var negotiators: [UInt8: NegotiatorV3] = [:]
        var dataChannels: [UInt8: DataChannel] = [:]
        var oldKeys: [UInt8] = []
        var currentNegotiatorKey: UInt8? {
            didSet {
                pp_log(ctx, .openvpn, .info, "Negotiator: Current key is \(currentNegotiatorKey?.description ?? "nil")")
            }
        }
        private var currentDataChannelKey: UInt8?
        var pushReply: PushReply?
        var pendingPingTask: Task<Void, Error>?
        var lastReceivedDate: Date?
        var lastDataCountDate: Date?
        var dataCount = BidirectionalState<Int>(withResetValue: 0)

        private let ctx: PartoutLoggerContext

        init(
            ctx: PartoutLoggerContext,
            dataLink: DataLink,
            withLocalOptions: Bool,
            linkMetadata: LinkMetadata
        ) {
            self.ctx = ctx
            self.dataLink = dataLink
            self.withLocalOptions = withLocalOptions
            self.linkMetadata = linkMetadata
        }

        var currentNegotiator: NegotiatorV3? {
            currentNegotiatorKey.flatMap {
                negotiators[$0]
            }
        }

        var currentDataPair: DataLinkPair? {
            currentDataChannelKey.map {
                DataLinkPair(link: dataLink, key: $0)
            }
        }

        mutating func setDataChannel(_ channel: DataChannel, forKey key: UInt8) {
            dataChannels[channel.key] = channel
            if let currentDataChannelKey {
                oldKeys.append(currentDataChannelKey)
            }
            currentDataChannelKey = key
            pp_log(ctx, .openvpn, .info, "Data: Current key is \(key.description)")
        }

        mutating func reset() {
            for neg in negotiators.values {
                neg.cancel()
            }
            negotiators.removeAll()
            dataChannels.removeAll()
            oldKeys.removeAll()
            pendingPingTask?.cancel()
            dataCount.reset()
            currentNegotiatorKey = nil
            currentDataChannelKey = nil
            pushReply = nil
            pendingPingTask = nil
            lastDataCountDate = nil
        }
    }

    struct DataLinkPair {
        fileprivate let link: DataLink
        fileprivate let key: UInt8

        func send(_ packets: [Data], on key: UInt8? = nil) throws {
            try link.send(packets, on: key ?? self.key)
        }

        func receive(_ packets: [Data], on key: UInt8) throws {
            try link.receive(packets, on: key)
        }
    }
}

extension OpenVPNSessionV3 {
    var activePhase: ActivePhase? {
        preconditionOnQueue()
        guard case .active(let phase, _) = sessionState else {
            return nil
        }
        return phase
    }

    var idleContext: IdleContext? {
        preconditionOnQueue()
        guard case .stopped(let context) = sessionState else {
            return nil
        }
        return context
    }

    var activeContext: ActiveContext? {
        preconditionOnQueue()
        guard case .active(_, let context) = sessionState else {
            return nil
        }
        return context
    }

    @discardableResult
    func withActiveContext<R>(
        _ body: (inout ActivePhase, inout ActiveContext) throws -> R
    ) rethrows -> R? {
        preconditionOnQueue()
        guard case .active(var phase, var context) = sessionState else {
            return nil
        }
        let result = try body(&phase, &context)
        sessionState = .active(phase, context)
        return result
    }

    @discardableResult
    func withActiveContext<R>(
        _ body: (inout ActiveContext) throws -> R
    ) rethrows -> R? {
        try withActiveContext { _, context in
            try body(&context)
        }
    }
}
