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
    Transport(RuntimeLoop &, std::unique_ptr<Socket> value);
    Transport(RuntimeLoop &, std::unique_ptr<Tun> value);

    RuntimeLoop &Loop() const {
        return loop_;
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
    RuntimeLoop &loop_; // Borrowed from the runtime, including queued destruction.
    std::atomic<int32_t> status_{0};
    std::mutex receive_mutex_;
    Receiver receive_;
};

// C ABI conversion only; native consumers own Transport directly.
namespace ABI {
winrt_transport *Wrap(std::unique_ptr<Transport>);
}
} // namespace Partout
