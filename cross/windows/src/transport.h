// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include "socket.h"
#include "tun.h"
#include "loop.h"
#include <atomic>
#include <mutex>

namespace Partout {
// Native implementation details never appear in the C runtime interface.
class Transport {
public:
    Transport(winrt_loop, std::unique_ptr<Socket> value);
    Transport(winrt_loop, std::unique_ptr<Tun> value);
    winrt_loop Runtime() const { return runtime_; }
    winrt_transport api{};
    std::unique_ptr<Socket> socket;
    std::unique_ptr<Tun> tun;
private:
    void Initialize(bool unconnected);
    bool Subscribe(winrt_receive, void *);
    bool Deliver(const uint8_t *, size_t, const winrt_address *, int32_t);
    void StopWrites();
    int32_t Write(const uint8_t *, size_t, const winrt_address *);
    winrt_loop runtime_;
    std::atomic<int32_t> status_{0};
    std::mutex receive_mutex_;
    winrt_receive receive_ = nullptr;
    void *context_ = nullptr;
};
}
