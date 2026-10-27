// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "transport.h"
#include "winrt/abi.h"
#include <algorithm>
#include <string>

namespace {
template<typename To, typename From> To ConvertAddress(const From &value) {
    To result{};
    std::copy(std::begin(value.address), std::end(value.address), std::begin(result.address));
    result.scope_id = value.scope_id;
    result.port = value.port;
    result.family = value.family;
    return result;
}

struct TransportHandle {
    std::unique_ptr<Partout::Transport> handle;
    winrt_transport api;

    explicit TransportHandle(std::unique_ptr<Partout::Transport> value) : handle(std::move(value)), api{
        this,
        [](void *raw) {
            auto self = static_cast<TransportHandle *>(raw);
            self->handle->StopWrites();
            self->handle->Subscribe({});
            // Drain callbacks now; destroy on the worker after accepted commands.
            // Move the loop reference to the caller so deletion cannot self-join.
            auto loop = self->handle->TakeLoop();
            try { loop->Post([self] { delete self; }); }
            catch (...) { loop->Invoke([self] { delete self; }); }
        },
        [](void *raw, winrt_receive receive, void *context) {
            auto self = static_cast<TransportHandle *>(raw);
            try {
                if (!receive) return self->handle->Subscribe({});
                Partout::Transport::Receiver receiver = [=](const uint8_t *bytes, size_t size, const Partout::SocketAddress *source, int32_t error) {
                    winrt_address address{};
                    if (source) address = ConvertAddress<winrt_address>(*source);
                    return receive(context, bytes, size, source ? &address : nullptr, error);
                };
                return self->handle->Loop()->Invoke([&] { return self->handle->Subscribe(std::move(receiver)); });
            } catch (...) { return false; }
        },
        [](void *raw) { return static_cast<TransportHandle *>(raw)->handle->ResumeReading(); },
        [](void *raw) { static_cast<TransportHandle *>(raw)->handle->StopWrites(); },
        [](void *raw, const uint8_t *bytes, size_t size, const winrt_address *destination) {
            Partout::SocketAddress address{};
            if (destination) address = ConvertAddress<Partout::SocketAddress>(*destination);
            return static_cast<TransportHandle *>(raw)->handle->Write(bytes, size, destination ? &address : nullptr);
        },
        [](void *raw, winrt_address *result) {
            Partout::SocketAddress address{};
            if (!static_cast<TransportHandle *>(raw)->handle->GetAddress(&address)) return false;
            *result = ConvertAddress<winrt_address>(address);
            return true;
        },
        handle->IsUnconnected()
    } {}
};
}

namespace Partout::ABI {
winrt_transport *Wrap(std::unique_ptr<Transport> transport) {
    auto wrapper = std::make_unique<TransportHandle>(std::move(transport));
    auto api = &wrapper->api;
    wrapper.release();
    return api;
}
}

struct __winrt_loop_struct {
    std::shared_ptr<Partout::RuntimeLoop> handle = std::make_shared<Partout::RuntimeLoop>();
};
extern "C" {
winrt_loop winrt_loop_create(void) {
    try { return new __winrt_loop_struct{}; } catch (...) { return nullptr; }
}
bool winrt_loop_submit(winrt_loop loop, void (*execute)(void *), void *context) {
    try {
        loop->handle->Post([=] { execute(context); });
        return true;
    } catch (...) { return false; }
}
void winrt_loop_free(winrt_loop loop) {
    if (!loop) return;
    // Setup may publish a retained transport while the owner closes.
    if (!loop->handle->IsWorker()) loop->handle->Invoke([] {});
    delete loop;
}

winrt_transport *winrt_connect(const char *host, uint16_t port,
    const winrt_connect_options *options) {
    try {
        auto loop = Partout::RuntimeLoop::Current();
        if (!loop) loop = std::make_shared<Partout::RuntimeLoop>();
        // The caller retains the loop until Invoke returns; commands borrow it.
        return loop->Invoke([&loop, host = std::string{host}, port, settings = *options]() -> winrt_transport * {
            auto transport = std::make_unique<Partout::Transport>(loop,
                std::make_unique<Partout::Socket>(settings.tcp ? Partout::SocketProtoTCP : Partout::SocketProtoUDP, settings.unconnected));
            if (settings.configure && !settings.configure(settings.context, reinterpret_cast<uintptr_t>(transport.get()))) return nullptr;
            Partout::SocketOpenOptions options{settings.dual_stack, settings.timeout_ms};
            if (!transport->socket->Open(host.c_str(), port, &options)) return nullptr;
            return Partout::ABI::Wrap(std::move(transport));
        });
    } catch (...) { return nullptr; }
}
}
