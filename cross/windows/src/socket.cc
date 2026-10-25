// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include "socket.h"
#include "winrt/log.h"
#include <winrt/Windows.Networking.Sockets.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Networking.h>
#include <chrono>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Networking;
using namespace winrt::Windows::Networking::Sockets;
using namespace winrt::Windows::Storage::Streams;

// Creation, configuration and open are separate calls. An MTA usage cookie
// keeps WinRT objects valid between them, including on uninitialized Zig threads.
struct SocketApartment {
    CO_MTA_USAGE_COOKIE cookie{};
    SocketApartment() { check_hresult(CoIncrementMTAUsage(&cookie)); }
    ~SocketApartment() { CoDecrementMTAUsage(cookie); }
};

// Outstanding OS operations retain this state rather than the socket wrapper.
// Serializing delivery also lets callback removal drain the borrowed context.
struct SocketReceiveState {
    std::shared_ptr<SocketApartment> apartment;
    std::mutex mutex;
    std::mutex write_mutex;
    std::function<int32_t(const uint8_t *, size_t)> channel_write;
    std::atomic<bool> writes_stopped{false};
    std::atomic<uint64_t> received{0}, sent{0};
    winrt_socket_on_receive callback = nullptr;
    void *context = nullptr;
    bool reading = false;
    bool paused = false;
    bool channel_owned = false;
    std::condition_variable read_stopped;

    bool prepareReadLocked(bool has_stream) {
        paused = false;
        if (!callback || !has_stream || reading || channel_owned) return false;
        reading = true;
        return true;
    }

    void deliver(const uint8_t *bytes, size_t size,
                 const winrt_socket_address *source, int32_t error) {
        std::lock_guard lock(mutex);
        deliverLocked(bytes, size, source, error);
    }

    void deliverLocked(const uint8_t *bytes, size_t size,
                       const winrt_socket_address *source, int32_t error) {
        if (!callback || (paused && !error)) return;
        if (error) winrt_log(WinrtLogError,
            "WinRT socket receive failed: code=0x%08x (1=TCP EOF), channel_owned=%s",
            static_cast<unsigned int>(error), channel_owned ? "true" : "false");
        paused = !callback(context, bytes, size, source, error);
    }
};

namespace {

// Open runs on the daemon's worker, which need not already have a COM apartment.
struct Apartment {
    Apartment() { init_apartment(apartment_type::multi_threaded); }
    ~Apartment() { uninit_apartment(); }
};

void wait_for_connect(IAsyncAction const &action, int timeout_ms) {
    if (action.wait_for(std::chrono::milliseconds(timeout_ms)) == AsyncStatus::Started) {
        action.Cancel();
        throw hresult_error(HRESULT_FROM_WIN32(ERROR_TIMEOUT), L"WinRT socket connect timed out");
    }
    action.GetResults();
}

winrt_socket_address socket_address(HostName const &host, hstring const &port) {
    if (!host || (host.Type() != HostNameType::Ipv4 && host.Type() != HostNameType::Ipv6))
        throw hresult_invalid_argument();
    winrt_socket_address result{};
    auto text = std::wstring(host.CanonicalName());
    const auto zone = text.find(L'%');
    if (zone != std::wstring::npos) {
        result.scope_id = static_cast<uint32_t>(std::stoul(text.substr(zone + 1)));
        text.resize(zone);
    }
    const bool ipv4 = host.Type() == HostNameType::Ipv4;
    result.family = ipv4 ? 4 : 6;
    if (InetPtonW(ipv4 ? AF_INET : AF_INET6, text.c_str(), result.address) != 1)
        throw hresult_invalid_argument();
    const auto number = std::stoul(std::wstring(port));
    if (number > UINT16_MAX) throw hresult_invalid_argument();
    result.port = static_cast<uint16_t>(number);
    return result;
}

fire_and_forget read_stream(std::shared_ptr<SocketReceiveState> state, StreamSocket stream) {
    try {
        co_await resume_background();
        Buffer buffer{64 * 1024};
        for (;;) {
            IAsyncOperationWithProgress<IBuffer, uint32_t> read{nullptr};
            {
                std::lock_guard lock(state->mutex);
                if (!state->callback || state->paused || state->channel_owned) {
                    state->reading = false;
                    state->read_stopped.notify_all();
                    co_return;
                }
                read = stream.InputStream().ReadAsync(buffer, buffer.Capacity(), InputStreamOptions::Partial);
            }
            auto received = co_await read;
            if (received.Length() == 0) {
                std::lock_guard lock(state->mutex);
                state->reading = false;
                state->read_stopped.notify_all();
                if (state->channel_owned) co_return;
                state->deliverLocked(nullptr, 0, nullptr, 1);
                co_return;
            }
            state->deliver(received.data(), received.Length(), nullptr, 0);
        }
    } catch (...) {
        std::lock_guard lock(state->mutex);
        state->reading = false;
        state->read_stopped.notify_all();
        if (state->channel_owned) co_return;
        state->deliverLocked(nullptr, 0, nullptr, to_hresult().value);
    }
}

} // namespace

namespace Partout {

Socket::Socket(winrt_socket_proto proto, bool unconnected) {
    if (proto != WinrtSocketProtoUDP && proto != WinrtSocketProtoTCP)
        throw hresult_invalid_argument();
    if (unconnected && proto != WinrtSocketProtoUDP) throw hresult_invalid_argument();
    Apartment apartment;
    unconnected_ = unconnected;
    apartment_ = std::make_shared<SocketApartment>();
    receive_state_ = std::make_shared<SocketReceiveState>();
    receive_state_->apartment = apartment_;
    if (proto == WinrtSocketProtoUDP) datagram_ = DatagramSocket{};
    else stream_ = StreamSocket{};
}

Socket::~Socket() noexcept {
    SetOnReceive(nullptr, nullptr);
    if (adapter_) winrt_log(WinrtLogNotice, "WinRT independent UDP totals: received=%llu, sent=%llu",
        receive_state_->received.load(), receive_state_->sent.load());
    // Each cleanup is independent, so a failed event revocation cannot skip Close.
    try { if (datagram_ && receiving_) datagram_.MessageReceived(receive_token_); } catch (...) {}
    try { if (datagram_) datagram_.Close(); } catch (...) {}
    try { if (stream_) stream_.Close(); } catch (...) {}
}

bool Socket::Open(const char *hostname, uint16_t port,
    const winrt_socket_open_options *options) {
    try {
        if (!hostname || !*hostname || !options || options->timeout_ms < 0 ||
            (options->dual_stack && !unconnected_)) {
            throw hresult_invalid_argument();
        }
        Apartment apartment;
        const HostName host{to_hstring(hostname)};
        const bool numeric = host.Type() == HostNameType::Ipv4 || host.Type() == HostNameType::Ipv6;
        const bool unconnected = unconnected_;
        if ((unconnected && !numeric) ||
            (options->dual_stack && host.Type() != HostNameType::Ipv6)) {
            throw hresult_invalid_argument();
        }
        const auto service = to_hstring(port);
        if (unconnected) {
            accepts_ipv4_ = host.Type() == HostNameType::Ipv4 || options->dual_stack;
            accepts_ipv6_ = host.Type() == HostNameType::Ipv6;
        }
        if (datagram_) {
            RegisterDatagram();
        }
        if (unconnected) {
            // WinRT rejects 0.0.0.0 as a BindEndpointAsync hostname. A service
            // bind covers all interfaces; the receive handler enforces family
            // policy because WinRT exposes no IPV6_V6ONLY control.
            const bool ipv4_wildcard = host.CanonicalName() == L"0.0.0.0";
            const bool ipv6_wildcard = host.CanonicalName() == L"::";
            const auto local_service = port == 0 ? hstring{} : service;
            if (adapter_) {
                if (!ipv4_wildcard && !ipv6_wildcard) throw hresult_invalid_argument();
                datagram_.BindServiceNameAsync(local_service, adapter_).get();
                winrt_log(WinrtLogNotice, "WinRT independent UDP: bound port %ls on adapter %ls",
                    datagram_.Information().LocalPort().c_str(),
                    to_hstring(adapter_.NetworkAdapterId()).c_str());
            } else if (ipv4_wildcard || (options->dual_stack && ipv6_wildcard)) {
                datagram_.BindServiceNameAsync(local_service).get();
            } else {
                datagram_.BindEndpointAsync(host, local_service).get();
            }
            bound_host_ = host;
        } else if (datagram_) {
            wait_for_connect(datagram_.ConnectAsync(host, service), options->timeout_ms);
        } else {
            wait_for_connect(stream_.ConnectAsync(host, service, SocketProtectionLevel::PlainSocket),
                options->timeout_ms);
        }
        winrt_log(WinrtLogDebug, "WinRT socket: Opened %s %s:%u, mode=%s, dual_stack=%s",
            datagram_ ? "UDP" : "TCP", hostname, static_cast<unsigned int>(port),
            unconnected ? "unconnected (bound)" : "connected",
            options->dual_stack ? "true" : "false");
        return true;
    } catch (hresult_error const &error) {
        // Conversion allocates; diagnostics must not throw across the C ABI.
        try {
            const auto message = to_string(error.message());
            winrt_log(WinrtLogError, "winrt_socket_open failed: HRESULT 0x%08x (%s)",
                static_cast<unsigned int>(error.code().value), message.c_str());
        } catch (...) {}
    } catch (...) {
        winrt_log(WinrtLogError, "winrt_socket_open failed: unexpected exception");
    }
    return false;
}

bool Socket::SetOnReceive(winrt_socket_on_receive callback, void *context) {
    if (!receive_state_) return false;
    const auto state = receive_state_;
    try {
        bool start_read;
        {
            std::lock_guard lock(state->mutex);
            if (callback && state->callback) return false;
            state->callback = callback;
            state->context = context;
            start_read = state->prepareReadLocked(static_cast<bool>(stream_));
        }
        if (!start_read) return true;
        read_stream(state, stream_);
        return true;
    } catch (...) {
        std::lock_guard lock(state->mutex);
        state->callback = nullptr;
        state->context = nullptr;
        state->reading = false;
        return false;
    }
}

bool Socket::ResumeReading() {
    if (!receive_state_) return false;
    const auto state = receive_state_;
    try {
        bool start_read;
        {
            std::lock_guard lock(state->mutex);
            // Resume must never restore a cleared context.
            if (!state->callback) return false;
            start_read = state->prepareReadLocked(static_cast<bool>(stream_));
        }
        if (!start_read) return true;
        read_stream(state, stream_);
        return true;
    } catch (...) {
        std::lock_guard lock(state->mutex);
        state->reading = false;
        state->deliverLocked(nullptr, 0, nullptr, to_hresult().value);
        return false;
    }
}

int32_t Socket::Write(const uint8_t *bytes, size_t length,
    const winrt_socket_address *destination) {
    try {
        if ((!bytes && length) || length > UINT32_MAX)
            throw hresult_invalid_argument();
        Apartment apartment;
        const auto state = receive_state_;
        const auto stream = stream_;
        const auto datagram = datagram_;
        const bool unconnected = unconnected_;
        const bool ipv4 = accepts_ipv4_, ipv6 = accepts_ipv6_;
        // Retain transports and the lock independently of wrapper destruction.
        std::lock_guard lock(state->write_mutex);
        if (state->writes_stopped.load()) return E_ABORT;
        if (state->channel_write) {
            check_hresult(state->channel_write(bytes, length));
            return 0;
        }
        IOutputStream output{nullptr};
        if (stream) {
            output = stream.OutputStream();
        } else if (!unconnected) {
            output = datagram.OutputStream();
        } else {
            if (!destination || (destination->family != 4 && destination->family != 6) ||
                (destination->family == 4 && !ipv4) ||
                (destination->family == 6 && !ipv6))
                throw hresult_invalid_argument();
            wchar_t address[INET6_ADDRSTRLEN]{};
            if (!InetNtopW(destination->family == 4 ? AF_INET : AF_INET6,
                const_cast<uint8_t *>(destination->address), address, INET6_ADDRSTRLEN))
                throw hresult_invalid_argument();
            std::wstring host{address};
            if (destination->family == 6 && destination->scope_id)
                host += L"%" + std::to_wstring(destination->scope_id);
            output = datagram.GetOutputStreamAsync(
                HostName{host}, to_hstring(destination->port)).get();
        }
        // Keep each UDP packet in a single WriteAsync. TCP may complete short.
        size_t offset = 0;
        do {
            Buffer buffer{static_cast<uint32_t>(length - offset)};
            buffer.Length(buffer.Capacity());
            if (buffer.Length()) memcpy(buffer.data(), bytes + offset, buffer.Length());
            const auto written = output.WriteAsync(buffer).get();
            if (written > buffer.Length() ||
                (datagram && written != buffer.Length()) ||
                (stream && buffer.Length() && !written))
                throw hresult_error(HRESULT_FROM_WIN32(ERROR_WRITE_FAULT));
            offset += written;
        } while (offset < length);
        state->sent.fetch_add(1, std::memory_order_relaxed);
        return 0;
    } catch (...) {
        const auto error = to_hresult().value;
        winrt_log(WinrtLogError, "WinRT socket write failed: HRESULT 0x%08x, length=%zu",
            static_cast<unsigned int>(error), length);
        return error;
    }
}

void Socket::StopWrites() {
    if (!receive_state_) return;
    receive_state_->writes_stopped.store(true);
}

bool Socket::GetAddress(winrt_socket_address *address) {
    if (!address) return false;
    try {
        Apartment apartment;
        HostName host{nullptr};
        hstring port;
        if (datagram_) {
            const auto info = datagram_.Information();
            host = info.LocalAddress();
            port = info.LocalPort();
            // Service binds may report :: even for our IPv4-only policy.
            // Preserve the requested binding while using the OS-assigned port.
            if (bound_host_) host = bound_host_;
        } else if (stream_) {
            const auto info = stream_.Information();
            host = info.LocalAddress();
            port = info.LocalPort();
        }
        *address = socket_address(host, port);
        return true;
    } catch (...) {
        return false;
    }
}

IInspectable Socket::Transport() const {
    if (datagram_) return datagram_;
    return stream_;
}

bool Socket::IsUnconnected() const {
    return datagram_ && unconnected_;
}

void Socket::SetAdapter(
    winrt::Windows::Networking::Connectivity::NetworkAdapter const &adapter) {
    if (!IsUnconnected() || !adapter) throw hresult_invalid_argument();
    adapter_ = adapter;
}

std::function<void(const uint8_t *, size_t)> Socket::ChannelReceiver() const {
    return [state = receive_state_](const uint8_t *bytes, size_t length) {
        state->deliver(bytes, length, nullptr, 0);
    };
}

void Socket::TakeOver() {
    const auto state = receive_state_;
    std::lock_guard writes(state->write_mutex);
    {
        std::lock_guard lock(state->mutex);
        state->channel_owned = true;
    }
    if (datagram_ && receiving_) {
        datagram_.MessageReceived(receive_token_);
        receiving_ = false;
    }
    if (stream_) stream_.CancelIOAsync().get();
    std::unique_lock lock(state->mutex);
    state->read_stopped.wait(lock, [&] { return !state->reading; });
}

void Socket::SetChannelWriter(
    std::function<int32_t(const uint8_t *, size_t)> writer) {
    std::lock_guard lock(receive_state_->write_mutex);
    receive_state_->channel_write = std::move(writer);
}

void Socket::RegisterDatagram() {
    const auto state = receive_state_;
    // WinRT requires registration before bind/connect. Attach only changes
    // the consumer; the OS handler remains registered until the socket closes.
    receive_token_ = datagram_.MessageReceived(
        [state, unconnected = unconnected_, ipv4 = accepts_ipv4_, ipv6 = accepts_ipv6_](
            DatagramSocket const &, DatagramSocketMessageReceivedEventArgs const &args) {
            try {
                const auto family = args.RemoteAddress().Type();
                if ((family == HostNameType::Ipv4 && !ipv4) ||
                    (family == HostNameType::Ipv6 && !ipv6)) return;
                auto reader = args.GetDataReader();
                const auto buffer = reader.ReadBuffer(reader.UnconsumedBufferLength());
                winrt_socket_address source{};
                if (unconnected) source = socket_address(args.RemoteAddress(), args.RemotePort());
                state->received.fetch_add(1, std::memory_order_relaxed);
                state->deliver(buffer.data(), buffer.Length(),
                    unconnected ? &source : nullptr, 0);
            } catch (...) {
                state->deliver(nullptr, 0, nullptr, to_hresult().value);
            }
        });
    receiving_ = true;
}

} // namespace Partout

extern "C" {

void winrt_socket_free(winrt_socket socket) {
    delete socket;
}

winrt_socket winrt_socket_create(winrt_socket_proto proto, bool unconnected) {
    try {
        return new __winrt_socket_struct{{proto, unconnected}};
    } catch (...) {
        winrt_log(WinrtLogError, "winrt_socket_create failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
        return nullptr;
    }
}

bool winrt_socket_open(winrt_socket socket, const char *hostname, uint16_t port,
    const winrt_socket_open_options *options) {
    if (!socket) return false;
    return socket->handle.Open(hostname, port, options);
}

bool winrt_socket_set_on_receive(winrt_socket socket,
    winrt_socket_on_receive callback, void *context) {
    if (!socket) return false;
    return socket->handle.SetOnReceive(callback, context);
}

bool winrt_socket_resume_reading(winrt_socket socket) {
    if (!socket) return false;
    return socket->handle.ResumeReading();
}

int32_t winrt_socket_write(winrt_socket socket, const uint8_t *bytes, size_t length,
    const winrt_socket_address *destination) {
    if (!socket) return E_INVALIDARG;
    return socket->handle.Write(bytes, length, destination);
}

void winrt_socket_stop_writes(winrt_socket socket) {
    if (!socket) return;
    socket->handle.StopWrites();
}

bool winrt_socket_get_address(winrt_socket socket, winrt_socket_address *address) {
    if (!socket) return false;
    return socket->handle.GetAddress(address);
}

}
