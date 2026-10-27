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

winrt::Windows::Storage::Streams::Buffer CopyBuffer(const uint8_t *bytes, size_t size) {
    if ((!bytes && size) || size > UINT32_MAX) throw winrt::hresult_invalid_argument();
    winrt::Windows::Storage::Streams::Buffer buffer{static_cast<uint32_t>(size)};
    buffer.Length(static_cast<uint32_t>(size));
    if (size) memcpy(buffer.data(), bytes, size);
    return buffer;
}

struct SocketHandle {
    Partout::RuntimeLoop &loop; // Runtime outlives endpoints and their queued destruction.
    std::unique_ptr<Partout::Socket> socket;

    SocketHandle(Partout::RuntimeLoop &owner, std::unique_ptr<Partout::Socket> value)
        : loop(owner), socket(std::move(value)) {}

    bool ResumeReading() {
        try {
            loop.Post([this] {
                if (!socket->ResumeReading()) socket->ReportError(E_FAIL);
            });
            return true;
        } catch (...) {
            return false;
        }
    }

    bool GetAddress(Partout::SocketAddress *address) {
        return loop.Invoke([this, address] {
            return socket->GetAddress(address);
        });
    }

    int32_t Write(const uint8_t *bytes, size_t size, const Partout::SocketAddress *destination) {
        if (auto status = socket->WriteStatus()) return status;
        if (socket->IsUnconnected() && !destination) return E_INVALIDARG;
        if (!socket->Accepts(destination)) return E_INVALIDARG;
        try {
            auto buffer = CopyBuffer(bytes, size);
            std::optional<Partout::SocketAddress> address;
            if (destination) address = *destination;
            loop.Post([this, buffer = std::move(buffer), address]() mutable {
                if (socket->WriteStatus()) return;
                const auto result = socket->Write(std::move(buffer), address ? &*address : nullptr);
                if (result) socket->ReportError(result);
            });
            return 0;
        } catch (...) {
            return winrt::to_hresult().value;
        }
    }

    // Endpoint callback removal holds its delivery mutex until active calls
    // return. No callback storage or second delivery gate is needed here.
    bool Subscribe(winrt_receive receive, void *context) {
        if (!receive) return socket->SetOnReceive({});
        return loop.Invoke([this, receive, context] {
            return socket->SetOnReceive([receive, context](const uint8_t *bytes, size_t size,
                                                           const Partout::SocketAddress *source,
                                                           int32_t error) {
                winrt_address address{};
                if (source) address = ConvertAddress<winrt_address>(*source);
                return receive(context, bytes, size, source ? &address : nullptr, error);
            });
        });
    }

    winrt_transport api{
        .context = this,
        .release = [](void *raw) {
            auto self = static_cast<SocketHandle *>(raw);
            self->socket->StopWrites();
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
            auto self = static_cast<SocketHandle *>(raw);
            try {
                return self->Subscribe(receive, receive_context);
            } catch (...) {
                return false;
            }
        },
        .resume = [](void *raw) {
            return static_cast<SocketHandle *>(raw)->ResumeReading();
        },
        .stop = [](void *raw) {
            static_cast<SocketHandle *>(raw)->socket->StopWrites();
        },
        .write = [](void *raw, const uint8_t *bytes, size_t size, const winrt_address *destination) {
            Partout::SocketAddress address{};
            if (destination) address = ConvertAddress<Partout::SocketAddress>(*destination);
            return static_cast<SocketHandle *>(raw)->Write(bytes, size,
                                                           destination ? &address : nullptr);
        },
        .local_address = [](void *raw, winrt_address *result) {
            Partout::SocketAddress address{};
            if (!static_cast<SocketHandle *>(raw)->GetAddress(&address)) return false;
            *result = ConvertAddress<winrt_address>(address);
            return true;
        },
        .unconnected = socket->IsUnconnected()};
};

struct TunHandle {
    Partout::RuntimeLoop &loop;
    std::unique_ptr<Partout::Tun> tun;

    TunHandle(Partout::RuntimeLoop &owner, std::unique_ptr<Partout::Tun> value)
        : loop(owner), tun(std::move(value)) {}

    int32_t Write(const uint8_t *bytes, size_t size) {
        if (auto status = tun->WriteStatus()) return status;
        try {
            auto buffer = CopyBuffer(bytes, size);
            loop.Post([this, buffer = std::move(buffer)] {
                if (tun->WriteStatus()) return;
                const auto result = tun->Write(buffer.data(), buffer.Length());
                if (result) tun->ReportError(result);
            });
            return 0;
        } catch (...) {
            return winrt::to_hresult().value;
        }
    }

    bool Subscribe(winrt_receive receive, void *context) {
        // Removing the endpoint callback drains active delivery immediately.
        if (!receive) return tun->SetOnReceive({});
        return loop.Invoke([this, receive, context] {
            return tun->SetOnReceive(
                [receive, context](const uint8_t *bytes, size_t size, int32_t error) {
                    return receive(context, bytes, size, nullptr, error);
                });
        });
    }

    winrt_transport api{
        .context = this,
        .release = [](void *raw) {
            auto self = static_cast<TunHandle *>(raw);
            self->tun->StopWrites();
            self->Subscribe(nullptr, nullptr);
            // The controller outlives this handle and its queued writes/destruction.
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
            try {
                return static_cast<TunHandle *>(raw)->Subscribe(receive, receive_context);
            } catch (...) {
                return false;
            }
        },
        // TUN admission is controlled by the consumer; there is no native read loop.
        .resume = [](void *) {
            return true;
        },
        .stop = [](void *raw) {
            static_cast<TunHandle *>(raw)->tun->StopWrites();
        },
        .write = [](void *raw, const uint8_t *bytes, size_t size, const winrt_address *) {
            return static_cast<TunHandle *>(raw)->Write(bytes, size);
        },
        // A channel TUN has no bound socket address.
        .local_address = [](void *, winrt_address *) {
            return false;
        },
        .unconnected = false};
};
} // namespace

namespace Partout::ABI {
winrt_transport *WrapTun(RuntimeLoop &loop, std::unique_ptr<Tun> tun) {
    auto wrapper = std::make_unique<TunHandle>(loop, std::move(tun));
    auto api = &wrapper->api;
    wrapper.release();
    return api;
}

bool ConfigureSocket(TunnelController *controller, uintptr_t token) {
    const auto handle = reinterpret_cast<SocketHandle *>(token);
    if (!handle || !handle->socket) return false;
    if (!controller) return true;
    if (&controller->Loop() != &handle->loop) return false;
    return controller->Associate(*handle->socket);
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
            auto handle = std::make_unique<SocketHandle>(*loop, std::move(socket));
            const uintptr_t socket_token = reinterpret_cast<uintptr_t>(handle.get());
            if (settings.configure && !settings.configure(settings.context, socket_token))
                return nullptr;
            Partout::SocketOpenOptions options{settings.dual_stack, settings.timeout_ms};
            if (!handle->socket->Open(host.c_str(), port, &options)) return nullptr;
            auto api = &handle->api;
            handle.release();
            return api;
        });
    } catch (...) {
        return nullptr;
    }
}
}
