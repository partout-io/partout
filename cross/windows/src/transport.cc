// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <winsock2.h>
#include "transport.h"
#include <string>
#include <vector>
#include <optional>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Networking.Sockets.h>

namespace Partout {
Transport::Transport(winrt_loop runtime, std::unique_ptr<Socket> value)
    : socket(std::move(value)), runtime_(runtime) { Initialize(socket->IsUnconnected()); }
Transport::Transport(winrt_loop runtime, std::unique_ptr<Tun> value)
    : tun(std::move(value)), runtime_(runtime) { Initialize(false); }
void Transport::Initialize(bool unconnected) {
    api = {
        this,
        [](void *raw) {
            auto self = static_cast<Transport *>(raw);
            auto runtime = self->runtime_;
            Loop(runtime).Invoke([self] { self->StopWrites(); self->Subscribe(nullptr, nullptr); delete self; });
            // Final release is on the owning caller, never on the worker it joins.
            winrt_loop_free(runtime);
        },
        [](void *raw, winrt_receive receive, void *context) {
            auto self = static_cast<Transport *>(raw);
            return Loop(self->runtime_).Invoke([=] { return self->Subscribe(receive, context); });
        },
        [](void *raw) {
            auto self = static_cast<Transport *>(raw);
            try {
                Loop(self->runtime_).Post([=] {
                    if (self->socket && !self->socket->ResumeReading())
                        self->Deliver(nullptr, 0, nullptr, E_FAIL);
                });
                return true;
            } catch (...) { return false; }
        },
        [](void *raw) {
            auto self = static_cast<Transport *>(raw);
            self->status_ = E_ABORT;
            Loop(self->runtime_).Invoke([=] { self->StopWrites(); });
        },
        [](void *raw, const uint8_t *bytes, size_t length, const winrt_address *destination) {
            return static_cast<Transport *>(raw)->Write(bytes, length, destination);
        },
        [](void *raw, winrt_address *address) {
            auto self = static_cast<Transport *>(raw);
            return Loop(self->runtime_).Invoke([=] { return self->socket && self->socket->GetAddress(address); });
        },
        unconnected
    };
}
bool Transport::Subscribe(winrt_receive receive, void *context) {
    if (!receive) {
        if (socket) socket->SetOnReceive(nullptr, nullptr);
        else tun->SetOnReceive(nullptr, nullptr);
        std::lock_guard lock(receive_mutex_);
        receive_ = nullptr; context_ = nullptr;
        return true;
    }
    { std::lock_guard lock(receive_mutex_);
      if (receive_) return false;
      receive_ = receive; context_ = context; }
    bool registered = socket ? socket->SetOnReceive(
        [](void *raw, const uint8_t *bytes, size_t size, const winrt_address *address, int32_t error) {
            return static_cast<Transport *>(raw)->Deliver(bytes, size, address, error);
        }, this) : tun->SetOnReceive(
        [](void *raw, const uint8_t *bytes, size_t size) {
            return static_cast<Transport *>(raw)->Deliver(bytes, size, nullptr, 0);
        }, this);
    if (!registered) {
        std::lock_guard lock(receive_mutex_); receive_ = nullptr; context_ = nullptr;
    }
    return registered;
}
bool Transport::Deliver(const uint8_t *bytes, size_t size, const winrt_address *address, int32_t error) {
    if (error && error != WinrtEOF) {
        int32_t expected = 0;
        status_.compare_exchange_strong(expected, error);
    }
    std::lock_guard lock(receive_mutex_);
    return receive_ && receive_(context_, bytes, size, address, error);
}
void Transport::StopWrites() {
    status_ = E_ABORT;
    if (socket) socket->StopWrites(); else tun->StopWrites();
}
int32_t Transport::Write(const uint8_t *bytes, size_t size, const winrt_address *destination) {
    if (auto status = status_.load()) return status;
    if ((!bytes && size) || size > UINT32_MAX || (api.unconnected && !destination)) return E_INVALIDARG;
    if (socket && !socket->Accepts(destination)) return E_INVALIDARG;
    try {
        std::vector<uint8_t> copy;
        if (size) copy.assign(bytes, bytes + size);
        std::optional<winrt_address> address;
        if (destination) address = *destination;
        Loop(runtime_).Post([this, copy = std::move(copy), address] {
            if (status_) return;
            auto result = socket ? socket->Write(copy.data(), copy.size(), address ? &*address : nullptr) : tun->Write(copy.data(), copy.size());
            if (result) Deliver(nullptr, 0, nullptr, result);
        });
        return 0;
    } catch (...) { return winrt::to_hresult().value; }
}

static winrt_loop StandaloneLoop() {
    return winrt_loop_create();
}
}

extern "C" winrt_transport *winrt_connect(winrt_loop requested_runtime, const char *host, uint16_t port,
    const winrt_connect_options *options) {
    auto runtime = requested_runtime ? requested_runtime : Partout::CurrentLoop();
    if (runtime) Partout::RetainLoop(runtime);
    else runtime = Partout::StandaloneLoop();
    if (!runtime) return nullptr;
    try {
        auto result = Partout::Loop(runtime).Invoke([runtime, host = std::string{host}, port, settings = *options]() -> winrt_transport * {
            auto transport = std::make_unique<Partout::Transport>(runtime,
                std::make_unique<Partout::Socket>(settings.tcp ? Partout::SocketProtoTCP : Partout::SocketProtoUDP, settings.unconnected));
            if (settings.configure && !settings.configure(settings.context, reinterpret_cast<uintptr_t>(transport.get()))) return nullptr;
            Partout::SocketOpenOptions options{settings.dual_stack, settings.timeout_ms};
            if (!transport->socket->Open(host.c_str(), port, &options)) return nullptr;
            auto api = &transport->api;
            transport.release();
            return api;
        });
        if (result) return result;
    } catch (...) {}
    winrt_loop_free(runtime);
    return nullptr;
}
