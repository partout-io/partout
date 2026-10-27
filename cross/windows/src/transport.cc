// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <winsock2.h>
#include "transport.h"
#include <vector>
#include <optional>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Networking.Sockets.h>

namespace Partout {
Transport::Transport(std::shared_ptr<RuntimeLoop> loop, std::unique_ptr<Socket> value)
    : socket(std::move(value)), loop_(std::move(loop)) {}

Transport::Transport(std::shared_ptr<RuntimeLoop> loop, std::unique_ptr<Tun> value)
    : tun(std::move(value)), loop_(std::move(loop)) {}

bool Transport::Subscribe(Receiver receive) {
    if (!receive) {
        if (socket)
            socket->SetOnReceive(nullptr, nullptr);
        else
            tun->SetOnReceive(nullptr, nullptr);
        std::lock_guard lock(receive_mutex_);
        receive_ = {};
        return true;
    }
    {
        std::lock_guard lock(receive_mutex_);
        if (receive_)
            return false;
        receive_ = std::move(receive);
    }
    bool registered =
        socket ? socket->SetOnReceive(
                     [](void *raw, const uint8_t *bytes, size_t size, const SocketAddress *address,
                        int32_t error) {
                         return static_cast<Transport *>(raw)->Deliver(bytes, size, address, error);
                     },
                     this)
               : tun->SetOnReceive(
                     [](void *raw, const uint8_t *bytes, size_t size) {
                         return static_cast<Transport *>(raw)->Deliver(bytes, size, nullptr, 0);
                     },
                     this);
    if (!registered) {
        std::lock_guard lock(receive_mutex_);
        receive_ = {};
    }
    return registered;
}

bool Transport::Deliver(const uint8_t *bytes, size_t size, const SocketAddress *address,
                        int32_t error) {
    if (error && error != SocketEOF) {
        int32_t expected = 0;
        status_.compare_exchange_strong(expected, error);
    }
    std::lock_guard lock(receive_mutex_);
    return receive_ && receive_(bytes, size, address, error);
}

bool Transport::ResumeReading() {
    try {
        loop_->Post([this] {
            if (socket && !socket->ResumeReading())
                Deliver(nullptr, 0, nullptr, E_FAIL);
        });
        return true;
    } catch (...) {
        return false;
    }
}

bool Transport::GetAddress(SocketAddress *address) {
    return loop_->Invoke([this, address] {
        return socket && socket->GetAddress(address);
    });
}

void Transport::StopWrites() {
    status_ = E_ABORT;
    if (socket)
        socket->StopWrites();
    else
        tun->StopWrites();
}

int32_t Transport::Write(const uint8_t *bytes, size_t size, const SocketAddress *destination) {
    if (auto status = status_.load())
        return status;
    if ((!bytes && size) || size > UINT32_MAX || (IsUnconnected() && !destination))
        return E_INVALIDARG;
    if (socket && !socket->Accepts(destination))
        return E_INVALIDARG;
    try {
        std::vector<uint8_t> copy;
        if (size)
            copy.assign(bytes, bytes + size);
        std::optional<SocketAddress> address;
        if (destination)
            address = *destination;
        loop_->Post([this, copy = std::move(copy), address] {
            if (status_)
                return;
            auto result =
                socket ? socket->Write(copy.data(), copy.size(), address ? &*address : nullptr)
                       : tun->Write(copy.data(), copy.size());
            if (result)
                Deliver(nullptr, 0, nullptr, result);
        });
        return 0;
    } catch (...) {
        return winrt::to_hresult().value;
    }
}

} // namespace Partout
