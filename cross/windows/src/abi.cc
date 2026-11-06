// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <winsock2.h>
#include "abi.h"
#include "loop.h"
#include "socket.h"
#include "tun.h"
#include "io_metrics.h"
#include <algorithm>
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

// Copy descriptors only; payloads remain borrowed for synchronous submission.
bool PacketViews(const windows_packet *packets, size_t count, Partout::PacketView *views, size_t &bytes) {
    if (!packets || !count || count > Partout::MaxPacketBatch) return false;
    bytes = 0;
    for (size_t i = 0; i < count; ++i) {
        if ((!packets[i].data && packets[i].size) || packets[i].size > UINT32_MAX) return false;
        views[i] = {packets[i].data, packets[i].size};
        bytes += packets[i].size;
    }
    return true;
}
static_assert(WindowsMaxBatch == Partout::MaxPacketBatch);

struct SocketHandle {
    Partout::RuntimeLoop &loop; // Runtime outlives endpoints and their queued destruction.
    std::unique_ptr<Partout::Socket> socket;
    // The transport owner serializes submissions and release.
    Partout::IOTiming submit_time;
    Partout::IOBatches submitted_packets;

    SocketHandle(Partout::RuntimeLoop &owner, std::unique_ptr<Partout::Socket> value)
        : loop(owner), socket(std::move(value)) {}

    ~SocketHandle() {
        submit_time.Log(this, "socket.write_submit_not_completion");
        submitted_packets.Log(this, "socket.submitted");
    }

    bool ResumeReading() {
        try {
            loop.Schedule([this] {
                if (!socket->ResumeReading()) socket->ReportError(E_FAIL);
            });
            return true;
        } catch (...) {
            return false;
        }
    }

    bool GetAddress(Partout::SocketAddress *address) {
        return loop.Perform([this, address] {
            return socket->GetAddress(address);
        });
    }

    int32_t Write(const uint8_t *bytes, size_t size, const Partout::SocketAddress *destination) {
        if (auto status = socket->WriteStatus()) return status;
        if (socket->IsUnconnected() && !destination) return E_INVALIDARG;
        if (!socket->Accepts(destination)) return E_INVALIDARG;
        Partout::ScopedIOTiming timing(submit_time);
        submitted_packets.Add(1, size);
        // The socket consumes channel writes now and owns asynchronous buffers.
        // Return submission errors; the consumer owns failure dispatch.
        return socket->Write(bytes, size, destination);
    }

    int32_t WriteBatch(const windows_packet *packets, size_t count, const Partout::SocketAddress *destination, size_t *written) {
        if (!written) return E_INVALIDARG;
        *written = 0;
        Partout::PacketView views[Partout::MaxPacketBatch];
        size_t bytes = 0;
        if (!PacketViews(packets, count, views, bytes) || !socket->Accepts(destination)) return E_INVALIDARG;
        if (auto status = socket->WriteStatus()) return status;
        submitted_packets.Add(count, bytes);
        Partout::ScopedIOTiming timing(submit_time);
        return socket->WriteBatch(views, count, destination, written);
    }

    // Endpoint callback removal holds its delivery mutex until active calls
    // return. No callback storage or second delivery gate is needed here.
    bool Subscribe(windows_receive receive, void *context) {
        if (!receive) return socket->SetOnReceive({});
        return loop.Perform([this, receive, context] {
            return socket->SetOnReceive([receive, context](const uint8_t *bytes, size_t size,
                                                           const Partout::SocketAddress *source,
                                                           int32_t error) {
                windows_address address{};
                if (source) address = ConvertAddress<windows_address>(*source);
                return receive(context, bytes, size, source ? &address : nullptr, error);
            });
        });
    }

    windows_transport api{
        .context = this,
        .release = [](void *raw) {
            auto self = static_cast<SocketHandle *>(raw);
            self->socket->StopWrites();
            self->Subscribe(nullptr, nullptr);
            // Drain callbacks now; destroy on the worker after accepted commands.
            try {
                self->loop.Schedule([self] {
                    delete self;
                });
            } catch (...) {
                self->loop.Perform([self] {
                    delete self;
                });
            }
        },
        .subscribe = [](void *raw, windows_receive receive, void *receive_context) {
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
        .write = [](void *raw, const uint8_t *bytes, size_t size, const windows_address *destination) {
            Partout::SocketAddress address{};
            if (destination) address = ConvertAddress<Partout::SocketAddress>(*destination);
            return static_cast<SocketHandle *>(raw)->Write(bytes, size,
                                                           destination ? &address : nullptr);
        },
        .local_address = [](void *raw, windows_address *result) {
            Partout::SocketAddress address{};
            if (!static_cast<SocketHandle *>(raw)->GetAddress(&address)) return false;
            *result = ConvertAddress<windows_address>(address);
            return true;
        },
        .unconnected = socket->IsUnconnected(),
        .write_batch = [](void *raw, const windows_packet *packets, size_t count, const windows_address *destination, size_t *written) {
            Partout::SocketAddress address{};
            if (destination) address = ConvertAddress<Partout::SocketAddress>(*destination);
            return static_cast<SocketHandle *>(raw)->WriteBatch(packets, count, destination ? &address : nullptr, written);
        },
        .subscribe_batch = nullptr};
};

struct TunHandle {
    Partout::RuntimeLoop &loop;
    std::unique_ptr<Partout::Tun> tun;
    Partout::IOTiming submit_time;
    Partout::IOBatches submitted_packets;
    uint64_t stopped_batches = 0;

    TunHandle(Partout::RuntimeLoop &owner, std::unique_ptr<Partout::Tun> value)
        : loop(owner), tun(std::move(value)) {}

    ~TunHandle() {
        submit_time.Log(this, "tun.write_submit");
        submitted_packets.Log(this, "tun.submitted");
        windows_log(WindowsLogInfo, "IO metrics owner=%p stage=tun.stopped batches=%llu", this, stopped_batches);
    }

    int32_t Write(const uint8_t *bytes, size_t size) {
        submitted_packets.Add(1, size);
        if (auto status = tun->WriteStatus()) {
            ++stopped_batches;
            return status;
        }
        Partout::ScopedIOTiming timing(submit_time);
        try {
            return tun->Write(bytes, size);
        } catch (...) {
            return winrt::to_hresult().value;
        }
    }

    int32_t WriteBatch(const windows_packet *packets, size_t count, size_t *written) {
        if (!written) return E_INVALIDARG;
        *written = 0;
        Partout::PacketView views[Partout::MaxPacketBatch];
        size_t bytes = 0;
        if (!PacketViews(packets, count, views, bytes)) return E_INVALIDARG;
        submitted_packets.Add(count, bytes);
        if (auto status = tun->WriteStatus()) {
            ++stopped_batches;
            return status;
        }
        Partout::ScopedIOTiming timing(submit_time);
        try {
            return tun->WriteBatch(views, count, written);
        } catch (...) {
            return winrt::to_hresult().value;
        }
    }

    bool SubscribeBatch(windows_receive_batch receive, void *context) {
        if (!receive) return tun->SetOnReceiveBatch({});
        return loop.Perform([this, receive, context] {
            return tun->SetOnReceiveBatch([receive, context](const Partout::PacketView *packets, size_t count, int32_t error) {
                windows_packet views[Partout::MaxPacketBatch];
                for (size_t i = 0; i < count; ++i) views[i] = {packets[i].data, packets[i].size};
                return receive(context, views, count, nullptr, error);
            });
        });
    }

    bool Subscribe(windows_receive receive, void *context) {
        // Removing the endpoint callback drains active delivery immediately.
        if (!receive) return tun->SetOnReceive({});
        return loop.Perform([this, receive, context] {
            return tun->SetOnReceive(
                [receive, context](const uint8_t *bytes, size_t size, int32_t error) {
                    return receive(context, bytes, size, nullptr, error);
                });
        });
    }

    windows_transport api{
        .context = this,
        .release = [](void *raw) {
            auto self = static_cast<TunHandle *>(raw);
            self->tun->StopWrites();
            self->Subscribe(nullptr, nullptr);
            // The controller outlives this handle and its queued writes/destruction.
            try {
                self->loop.Schedule([self] {
                    delete self;
                });
            } catch (...) {
                self->loop.Perform([self] {
                    delete self;
                });
            }
        },
        .subscribe = [](void *raw, windows_receive receive, void *receive_context) {
            try {
                return static_cast<TunHandle *>(raw)->Subscribe(receive, receive_context);
            } catch (...) {
                return false;
            }
        },
        // TUN admission is controlled by the consumer; there is no native read loop.
        .resume =
            [](void *) {
                return true;
            },
        .stop =
            [](void *raw) {
                static_cast<TunHandle *>(raw)->tun->StopWrites();
            },
        .write =
            [](void *raw, const uint8_t *bytes, size_t size, const windows_address *) {
                return static_cast<TunHandle *>(raw)->Write(bytes, size);
            },
        // A channel TUN has no bound socket address.
        .local_address = [](void *, windows_address *) {
            return false;
        },
        .unconnected = false,
        .write_batch = [](void *raw, const windows_packet *packets, size_t count, const windows_address *, size_t *written) {
            return static_cast<TunHandle *>(raw)->WriteBatch(packets, count, written);
        },
        .subscribe_batch = [](void *raw, windows_receive_batch receive, void *context) {
            try {
                return static_cast<TunHandle *>(raw)->SubscribeBatch(receive, context);
            } catch (...) {
                return false;
            }
        }};
};
} // namespace

namespace Partout::ABI {
windows_transport *WrapTun(RuntimeLoop &loop, std::unique_ptr<Tun> tun) {
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
windows_loop windows_loop_create(void) {
    try {
        return new Partout::RuntimeLoop;
    } catch (...) {
        return nullptr;
    }
}

windows_loop windows_loop_current(void) {
    return Partout::RuntimeLoop::Current();
}

bool windows_loop_submit(windows_loop loop, void (*execute)(void *), void *context) {
    try {
        if (!loop) return false;
        loop->Schedule([=] {
            execute(context);
        });
        return true;
    } catch (...) {
        return false;
    }
}

void windows_loop_drain(windows_loop loop) {
    if (!loop) return;
    loop->Drain();
}

void windows_loop_free(windows_loop loop) {
    delete loop;
}

windows_transport *windows_connect(const char *host, uint16_t port,
                                   const windows_connect_options *options) {
    try {
        auto loop = Partout::RuntimeLoop::Current();
        if (!loop) return nullptr;
        return loop->Perform(
            [loop, host = std::string{host}, port, settings = *options]() -> windows_transport * {
                std::unique_ptr<Partout::Socket> socket = std::make_unique<Partout::Socket>(
                    settings.tcp ? Partout::SocketProtoTCP : Partout::SocketProtoUDP,
                    settings.unconnected);
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
