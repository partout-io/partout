// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <winsock2.h>
#include "abi.h"
#include "loop.h"
#include "socket.h"
#include "tun.h"
#include <algorithm>
#include <cstring>
#include <optional>
#include <string>

namespace {
template <typename To, typename From> To ConvertAddress(const From &value) {
    To result{};
    std::copy(std::begin(value.address), std::end(value.address), std::begin(result.address));
    result.scope_id = value.scope_id;
    result.port = value.port;
    result.family = value.family;
    return result;
}

struct TransportHandle {
    Partout::RuntimeLoop &loop; // Runtime outlives endpoints and their queued destruction.
    std::unique_ptr<Partout::Socket> socket;
    std::unique_ptr<Partout::Tun> tun;

    TransportHandle(Partout::RuntimeLoop &owner, std::unique_ptr<Partout::Socket> value)
        : loop(owner), socket(std::move(value)) {}

    TransportHandle(Partout::RuntimeLoop &owner, std::unique_ptr<Partout::Tun> value)
        : loop(owner), tun(std::move(value)) {}

    int32_t WriteStatus() const {
        return socket ? socket->WriteStatus() : tun->WriteStatus();
    }

    void ReportError(int32_t error) {
        if (socket)
            socket->ReportError(error);
        else
            tun->ReportError(error);
    }

    bool ResumeReading() {
        try {
            loop.Post([this] {
                if (socket && !socket->ResumeReading()) ReportError(E_FAIL);
            });
            return true;
        } catch (...) {
            return false;
        }
    }

    bool GetAddress(Partout::SocketAddress *address) {
        return loop.Invoke([this, address] {
            return socket && socket->GetAddress(address);
        });
    }

    void StopWrites() {
        if (socket)
            socket->StopWrites();
        else
            tun->StopWrites();
    }

    int32_t Write(const uint8_t *bytes, size_t size, const Partout::SocketAddress *destination) {
        if (auto status = WriteStatus()) return status;
        if ((!bytes && size) || size > UINT32_MAX ||
            (socket && socket->IsUnconnected() && !destination))
            return E_INVALIDARG;
        if (socket && !socket->Accepts(destination)) return E_INVALIDARG;
        try {
            winrt::Windows::Storage::Streams::Buffer buffer{static_cast<uint32_t>(size)};
            buffer.Length(static_cast<uint32_t>(size));
            if (size) memcpy(buffer.data(), bytes, size);
            std::optional<Partout::SocketAddress> address;
            if (destination) address = *destination;
            loop.Post([this, buffer = std::move(buffer), address]() mutable {
                if (WriteStatus()) return;
                const auto result =
                    socket ? socket->Write(std::move(buffer), address ? &*address : nullptr)
                           : tun->Write(buffer.data(), buffer.Length());
                if (result) ReportError(result);
            });
            return 0;
        } catch (...) {
            return winrt::to_hresult().value;
        }
    }

    // Endpoint callback removal holds its delivery mutex until active calls
    // return. No callback storage or second delivery gate is needed here.
    bool Subscribe(winrt_receive receive, void *context) {
        if (!receive) {
            return socket ? socket->SetOnReceive({}) : tun->SetOnReceive({});
        }
        return loop.Invoke([this, receive, context] {
            if (socket) {
                return socket->SetOnReceive([receive, context](const uint8_t *bytes, size_t size,
                                                               const Partout::SocketAddress *source,
                                                               int32_t error) {
                    winrt_address address{};
                    if (source) address = ConvertAddress<winrt_address>(*source);
                    return receive(context, bytes, size, source ? &address : nullptr, error);
                });
            }
            return tun->SetOnReceive(
                [receive, context](const uint8_t *bytes, size_t size, int32_t error) {
                    return receive(context, bytes, size, nullptr, error);
                });
        });
    }

    winrt_transport api{
        .context = this,
        .release = [](void *raw) {
            auto self = static_cast<TransportHandle *>(raw);
            self->StopWrites();
            self->Subscribe(nullptr, nullptr);
            // Drain callbacks now; destroy on the worker after accepted commands.
            try {
                self->loop.Post([self] {
                    delete self;
                });
            } catch (...) {
                self->loop.Invoke([self] {
                    delete self;
                });
            }
        },
        .subscribe = [](void *raw, winrt_receive receive, void *receive_context) {
            auto self = static_cast<TransportHandle *>(raw);
            try {
                return self->Subscribe(receive, receive_context);
            } catch (...) {
                return false;
            }
        },
        .resume = [](void *raw) {
            return static_cast<TransportHandle *>(raw)->ResumeReading();
        },
        .stop = [](void *raw) {
            static_cast<TransportHandle *>(raw)->StopWrites();
        },
        .write = [](void *raw, const uint8_t *bytes, size_t size, const winrt_address *destination) {
            Partout::SocketAddress address{};
            if (destination) address = ConvertAddress<Partout::SocketAddress>(*destination);
            return static_cast<TransportHandle *>(raw)->Write(bytes, size,
                                                              destination ? &address : nullptr);
        },
        .local_address = [](void *raw, winrt_address *result) {
            Partout::SocketAddress address{};
            if (!static_cast<TransportHandle *>(raw)->GetAddress(&address)) return false;
            *result = ConvertAddress<winrt_address>(address);
            return true;
        },
        .unconnected = socket && socket->IsUnconnected()};
};
} // namespace

namespace Partout::ABI {
winrt_transport *Wrap(RuntimeLoop &loop, std::unique_ptr<Tun> tun) {
    auto wrapper = std::make_unique<TransportHandle>(loop, std::move(tun));
    auto api = &wrapper->api;
    wrapper.release();
    return api;
}

bool ConfigureSocket(TunnelController *controller, uintptr_t token) {
    const auto transport = reinterpret_cast<TransportHandle *>(token);
    if (!transport || !transport->socket) return false;
    if (!controller) return true;
    if (&controller->Loop() != &transport->loop) return false;
    return controller->Associate(*transport->socket);
}
} // namespace Partout::ABI

extern "C" {
winrt_loop winrt_loop_create(void) {
    try {
        return new Partout::RuntimeLoop;
    } catch (...) {
        return nullptr;
    }
}

winrt_loop winrt_loop_current(void) {
    return Partout::RuntimeLoop::Current();
}

bool winrt_loop_submit(winrt_loop loop, void (*execute)(void *), void *context) {
    try {
        if (!loop) return false;
        loop->Post([=] {
            execute(context);
        });
        return true;
    } catch (...) {
        return false;
    }
}

void winrt_loop_drain(winrt_loop loop) {
    if (!loop) return;
    loop->Drain();
}

void winrt_loop_free(winrt_loop loop) {
    delete loop;
}

winrt_transport *winrt_connect(const char *host, uint16_t port,
                               const winrt_connect_options *options) {
    try {
        auto loop = Partout::RuntimeLoop::Current();
        if (!loop) return nullptr;
        return loop->Invoke([
            loop, host = std::string{host}, port,
            settings = *options
        ]() -> winrt_transport * {
            std::unique_ptr<Partout::Socket> socket = std::make_unique<Partout::Socket>(
                settings.tcp ? Partout::SocketProtoTCP : Partout::SocketProtoUDP,
                settings.unconnected
            );
            auto transport = std::make_unique<TransportHandle>(*loop, std::move(socket));
            const uintptr_t transport_ptr = reinterpret_cast<uintptr_t>(transport.get());
            if (settings.configure && !settings.configure(settings.context, transport_ptr))
                return nullptr;
            Partout::SocketOpenOptions options{settings.dual_stack, settings.timeout_ms};
            if (!transport->socket->Open(host.c_str(), port, &options)) return nullptr;
            auto api = &transport->api;
            transport.release();
            return api;
        });
    } catch (...) {
        return nullptr;
    }
}
}
