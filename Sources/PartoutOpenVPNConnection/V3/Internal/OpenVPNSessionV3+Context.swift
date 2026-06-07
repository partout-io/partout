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
        private let ctx: PartoutLoggerContext
        private let dataLink: DataLink
        var withLocalOptions: Bool
        let linkMetadata: LinkMetadata

        private var negotiators: [UInt8: NegotiatorV3]
        private var dataChannels: [UInt8: DataChannel]
        private var oldKeys: [UInt8]
        private var currentNegotiatorKey: UInt8?
        private(set) var currentDataPair: DataLinkPair?
        var pushReply: PushReply?
        var pendingPingTask: Task<Void, Error>?
        var lastReceivedDate: Date?
        var lastDataCountDate: Date?
        var dataCount: BidirectionalState<Int>

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
            negotiators = [:]
            dataChannels = [:]
            oldKeys = []
            dataCount = BidirectionalState(withResetValue: 0)
        }

        var currentNegotiator: NegotiatorV3? {
            currentNegotiatorKey.flatMap {
                negotiators[$0]
            }
        }

        var allNegotiatorKeys: [UInt8] {
            Array(negotiators.keys)
        }

        mutating func addNegotiator(_ negotiator: NegotiatorV3) {
            pp_log(ctx, .openvpn, .info, "Replace negotiator with key \(negotiator.key)")
            negotiators[negotiator.key] = negotiator
            pp_log(ctx, .openvpn, .info, "Negotiators: \(negotiators.keys)")
            currentNegotiatorKey = negotiator.key
            pp_log(ctx, .openvpn, .info, "Negotiator: Current key is \(negotiator.key.description)")
        }

        mutating func removeOldNegotiators() {
            while oldKeys.count > 1 {
                let keyToRemove = oldKeys.removeFirst()
                pp_log(ctx, .openvpn, .info, "Remove key \(keyToRemove) from negotiators and data channels")
                negotiators.removeValue(forKey: keyToRemove)
                dataChannels.removeValue(forKey: keyToRemove)
            }
        }

        var allDataKeys: [UInt8] {
            Array(dataChannels.keys)
        }

        func dataChannel(forKey key: UInt8) -> DataChannel? {
            dataChannels[key]
        }

        mutating func setDataChannel(_ channel: DataChannel, forKey key: UInt8) {
            dataChannels[channel.key] = channel
            if let currentDataPair {
                oldKeys.append(currentDataPair.key)
            }
            currentDataPair = DataLinkPair(link: dataLink, key: key)
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
            currentDataPair = nil
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
