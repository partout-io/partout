// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "loop.h"
#include "transport.h"
#include "winrt/io.h"
#include "winrt/log.h"
#include <winrt/base.h>
#include <string>
#include <stdexcept>
#include <algorithm>

namespace Partout {
namespace {
thread_local RuntimeLoop *current_loop = nullptr;
}

RuntimeLoop::RuntimeLoop() {
    auto started = started_.get_future();
    worker_ = std::thread([this] { Run(); });
    try { started.get(); }
    catch (...) { worker_.join(); throw; }
}
RuntimeLoop::~RuntimeLoop() {
    { std::lock_guard lock(mutex_); quitting_ = true; }
    changed_.notify_one();
    worker_.join();
}
bool RuntimeLoop::IsWorker() const { return std::this_thread::get_id() == worker_id_; }
void RuntimeLoop::Post(std::function<void()> command) {
    { std::lock_guard lock(mutex_);
      if (quitting_) throw std::runtime_error("RuntimeLoop is closed");
      commands_.push_back(std::move(command)); }
    changed_.notify_one();
}
void RuntimeLoop::Run() {
    worker_id_ = std::this_thread::get_id();
    try { winrt::init_apartment(winrt::apartment_type::multi_threaded); }
    catch (...) { started_.set_exception(std::current_exception()); return; }
    current_loop = this;
    started_.set_value();
    for (;;) {
        std::function<void()> command;
        {
            std::unique_lock lock(mutex_);
            changed_.wait(lock, [&] { return quitting_ || !commands_.empty(); });
            if (commands_.empty()) break;
            command = std::move(commands_.front());
            commands_.pop_front();
        }
        try { command(); }
        catch (...) { winrt_log(WinrtLogError, "Partout::RuntimeLoop: command failed: HRESULT=0x%08x",
            static_cast<unsigned>(winrt::to_hresult().value)); }
    }
    current_loop = nullptr;
    // Cached activation factories must not survive the apartment that supplied
    // them when the last native worker is released and a later one is created.
    winrt::clear_factory_cache();
    winrt::uninit_apartment();
}
}

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
            // Retain on the caller so final destruction never joins its own worker.
            auto loop = self->handle->Loop();
            loop->Invoke([self] {
                self->handle->StopWrites();
                self->handle->Subscribe({});
                delete self;
            });
        },
        [](void *raw, winrt_receive receive, void *context) {
            auto self = static_cast<TransportHandle *>(raw);
            try {
                Partout::Transport::Receiver receiver;
                if (receive) receiver = [=](const uint8_t *bytes, size_t size, const Partout::SocketAddress *source, int32_t error) {
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
        auto loop = Partout::current_loop ? Partout::current_loop->shared_from_this() : std::make_shared<Partout::RuntimeLoop>();
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
