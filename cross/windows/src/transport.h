// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "socket.h"
#include "tun.h"
#include "loop.h"
#include <atomic>
#include <mutex>

struct winrt_transport;

namespace Partout {
// Native implementation details never appear in the C runtime interface.
class Transport {
public:
    Transport(std::shared_ptr<RuntimeLoop>, std::unique_ptr<Socket> value);
    Transport(std::shared_ptr<RuntimeLoop>, std::unique_ptr<Tun> value);

    std::shared_ptr<RuntimeLoop> Loop() const {
        return loop_;
    }

    std::shared_ptr<RuntimeLoop> TakeLoop() {
        return std::move(loop_);
    }

    using Receiver = std::function<bool(const uint8_t *, size_t, const SocketAddress *, int32_t)>;

    bool IsUnconnected() const {
        return socket && socket->IsUnconnected();
    }

    bool Subscribe(Receiver);
    bool ResumeReading();
    void StopWrites();
    int32_t Write(const uint8_t *, size_t, const SocketAddress *);
    bool GetAddress(SocketAddress *);
    std::unique_ptr<Socket> socket;
    std::unique_ptr<Tun> tun;

private:
    bool Deliver(const uint8_t *, size_t, const SocketAddress *, int32_t);
    std::shared_ptr<RuntimeLoop> loop_;
    std::atomic<int32_t> status_{0};
    std::mutex receive_mutex_;
    Receiver receive_;
};

// C ABI conversion only; native consumers own Transport directly.
namespace ABI {
winrt_transport *Wrap(std::unique_ptr<Transport>);
}
} // namespace Partout
