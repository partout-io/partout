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
        var currentDataChannelKey: UInt8? {
            didSet {
                pp_log(ctx, .openvpn, .info, "Data: Current key is \(currentDataChannelKey?.description ?? "nil")")
            }
        }
        var pushReply: PushReply?
        var pendingPingTask: Task<Void, Error>?
        var lastReceivedDate: Date?
        var lastDataCountDate: Date?
        var dataCount = BidirectionalState<Int>(withResetValue: 0)

        private let ctx: PartoutLoggerContext

        init(ctx: PartoutLoggerContext, withLocalOptions: Bool, linkMetadata: LinkMetadata) {
            self.ctx = ctx
            self.withLocalOptions = withLocalOptions
            self.linkMetadata = linkMetadata
        }

        var currentNegotiator: NegotiatorV3? {
            currentNegotiatorKey.flatMap {
                negotiators[$0]
            }
        }

        var currentDataChannel: DataChannel? {
            currentDataChannelKey.flatMap {
                dataChannels[$0]
            }
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
}
