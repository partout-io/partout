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
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Networking;
using namespace winrt::Windows::Networking::Sockets;
using namespace winrt::Windows::Storage::Streams;

namespace {

// Open runs on the daemon's worker, which need not already have a COM apartment.
struct Apartment {
    Apartment() { init_apartment(apartment_type::multi_threaded); }
    ~Apartment() { uninit_apartment(); }
};

} // namespace

namespace Partout {

// Outstanding reads and writes retain this state rather than the socket wrapper.
// Serializing delivery also lets callback removal drain the borrowed context.
struct Socket::State {
    struct WriteRequest {
        Buffer buffer{nullptr};
        HostName host{nullptr};
        hstring service;
    };

    // Keep WinRT valid across calls and until the last native operation completes.
    CO_MTA_USAGE_COOKIE apartment{};
    std::mutex mutex;
    uint64_t received = 0;
    uint64_t sent = 0;
    // Zero accepts writes; E_ABORT stops them; other HRESULTs latch a failure.
    std::atomic<int32_t> write_status{0};
    // The front slot stays queued until completion, including while suspended.
    // A nonempty queue therefore already has a writer.
    std::deque<WriteRequest> writes;
    winrt_socket_on_receive callback = nullptr;
    void *context = nullptr;
    bool reading = false;
    bool paused = false;
    bool channel_owned = false;

    State() { check_hresult(CoIncrementMTAUsage(&apartment)); }
    ~State() {
        writes.clear();
        CoDecrementMTAUsage(apartment);
    }

    void finishReadLocked(int32_t error = 0) {
        reading = false;
        if (error && !channel_owned) deliverLocked(nullptr, 0, nullptr, error);
    }

    void deliver(const uint8_t *bytes, size_t size,
                 const winrt_socket_address *source, int32_t error) {
        std::lock_guard lock(mutex);
        if (!error) ++received;
        deliverLocked(bytes, size, source, error);
    }

    void deliverLocked(const uint8_t *bytes, size_t size,
                       const winrt_socket_address *source, int32_t error) {
        if (!callback || (paused && !error)) return;
        if (error) winrt_log(WinrtLogError,
            "WinRT socket I/O failed: code=0x%08x (1=TCP EOF), channel_owned=%s",
            static_cast<unsigned int>(error), channel_owned ? "true" : "false");
        paused = !callback(context, bytes, size, source, error);
    }
};

Socket::Socket(winrt_socket_proto proto, bool unconnected) {
    if (proto != WinrtSocketProtoUDP && proto != WinrtSocketProtoTCP)
        throw hresult_invalid_argument();
    if (unconnected && proto != WinrtSocketProtoUDP) throw hresult_invalid_argument();
    Apartment apartment;
    unconnected_ = unconnected;
    state_ = std::make_shared<State>();
    if (proto == WinrtSocketProtoUDP) datagram_ = DatagramSocket{};
    else stream_ = StreamSocket{};
}

Socket::~Socket() noexcept {
    StopWrites();
    SetOnReceive(nullptr, nullptr);
    if (adapter_) {
        std::lock_guard lock(state_->mutex);
        winrt_log(WinrtLogNotice, "WinRT independent UDP totals: received=%llu, sent=%llu",
            state_->received, state_->sent);
    }
    receive_registration_.revoke();
    // Close each transport independently.
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
        if ((unconnected_ && !numeric) ||
            (options->dual_stack && host.Type() != HostNameType::Ipv6)) {
            throw hresult_invalid_argument();
        }
        const auto service = to_hstring(port);
        if (unconnected_) {
            accepts_ipv4_ = host.Type() == HostNameType::Ipv4 || options->dual_stack;
            accepts_ipv6_ = host.Type() == HostNameType::Ipv6;
        }
        if (datagram_) {
            RegisterDatagram();
        }
        if (unconnected_) {
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
            WaitForConnect(datagram_.ConnectAsync(host, service), options->timeout_ms);
        } else {
            WaitForConnect(stream_.ConnectAsync(host, service, SocketProtectionLevel::PlainSocket),
                options->timeout_ms);
        }
        winrt_log(WinrtLogDebug, "WinRT socket: Opened %s %s:%u, mode=%s, dual_stack=%s",
            datagram_ ? "UDP" : "TCP", hostname, static_cast<unsigned int>(port),
            unconnected_ ? "unconnected (bound)" : "connected",
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
    const auto state = state_;
    {
        std::lock_guard lock(state->mutex);
        if (callback && state->callback) return false;
        state->callback = callback;
        state->context = context;
    }
    if (!callback || ResumeReading()) return true;
    SetOnReceive(nullptr, nullptr);
    return false;
}

bool Socket::ResumeReading() {
    const auto state = state_;
    {
        std::lock_guard lock(state->mutex);
        // Resume must never restore a cleared context.
        if (!state->callback) return false;
        state->paused = false;
        if (!stream_ || state->reading || state->channel_owned) return true;
        state->reading = true;
    }
    try {
        read_ = ReadStream(state, stream_);
        return true;
    } catch (...) {
        std::lock_guard lock(state->mutex);
        state->reading = false;
        return false;
    }
}

int32_t Socket::Write(const uint8_t *bytes, size_t length,
    const winrt_socket_address *destination) {
    try {
        if ((!bytes && length) || length > UINT32_MAX)
            throw hresult_invalid_argument();
        Apartment apartment;
        const auto state = state_;
        const auto status = state->write_status.load();
        if (status) return status;
        if (channel_write_) {
            check_hresult(channel_write_(bytes, length));
            return 0;
        }
        State::WriteRequest request;
        if (unconnected_) {
            if (!destination || (destination->family != 4 && destination->family != 6) ||
                (destination->family == 4 && !accepts_ipv4_) ||
                (destination->family == 6 && !accepts_ipv6_))
                throw hresult_invalid_argument();
            wchar_t address[INET6_ADDRSTRLEN]{};
            if (!InetNtopW(destination->family == 4 ? AF_INET : AF_INET6,
                const_cast<uint8_t *>(destination->address), address, INET6_ADDRSTRLEN))
                throw hresult_invalid_argument();
            std::wstring host{address};
            if (destination->family == 6 && destination->scope_id)
                host += L"%" + std::to_wstring(destination->scope_id);
            request.host = HostName{host};
            request.service = to_hstring(destination->port);
        }
        request.buffer = Buffer{static_cast<uint32_t>(length)};
        request.buffer.Length(static_cast<uint32_t>(length));
        if (length) memcpy(request.buffer.data(), bytes, length);
        bool start;
        {
            std::lock_guard lock(state->mutex);
            start = state->writes.empty();
            state->writes.push_back(std::move(request));
        }
        if (start) {
            try {
                write_ = WriteQueued(state, datagram_, stream_);
            } catch (...) {
                std::lock_guard lock(state->mutex);
                state->writes.clear();
                throw;
            }
        }
        return 0;
    } catch (...) {
        const auto error = to_hresult().value;
        winrt_log(WinrtLogError, "WinRT socket write failed: HRESULT 0x%08x, length=%zu",
            static_cast<unsigned int>(error), length);
        return error;
    }
}

void Socket::StopWrites() {
    state_->write_status.store(E_ABORT);
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
        } else {
            const auto info = stream_.Information();
            host = info.LocalAddress();
            port = info.LocalPort();
        }
        *address = ParseAddress(host, port);
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
    return unconnected_;
}

void Socket::SetAdapter(
    winrt::Windows::Networking::Connectivity::NetworkAdapter const &adapter) {
    if (!IsUnconnected() || !adapter) throw hresult_invalid_argument();
    adapter_ = adapter;
}

std::function<void(const uint8_t *, size_t)> Socket::ChannelReceiver() const {
    return [state = state_](const uint8_t *bytes, size_t length) {
        state->deliver(bytes, length, nullptr, 0);
    };
}

void Socket::TakeOver() {
    const auto state = state_;
    // Negotiation packets must reach the transport before VpnChannel owns it.
    if (write_) write_.get();
    check_hresult(state->write_status.load());
    {
        std::lock_guard lock(state->mutex);
        state->channel_owned = true;
    }
    receive_registration_.revoke();
    if (stream_) stream_.CancelIOAsync().get();
    if (read_) read_.get();
}

void Socket::SetChannelWriter(
    std::function<int32_t(const uint8_t *, size_t)> writer) {
    channel_write_ = std::move(writer);
}

void Socket::WaitForConnect(IAsyncAction const &action, int timeout_ms) {
    if (action.wait_for(std::chrono::milliseconds(timeout_ms)) == AsyncStatus::Started) {
        action.Cancel();
        throw hresult_error(HRESULT_FROM_WIN32(ERROR_TIMEOUT), L"WinRT socket connect timed out");
    }
    action.GetResults();
}

winrt_socket_address Socket::ParseAddress(HostName const &host, hstring const &port) {
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

IAsyncAction Socket::ReadStream(std::shared_ptr<State> state, StreamSocket stream) {
    try {
        co_await resume_background();
        Buffer buffer{64 * 1024};
        for (;;) {
            IAsyncOperationWithProgress<IBuffer, uint32_t> read{nullptr};
            {
                std::lock_guard lock(state->mutex);
                if (!state->callback || state->paused || state->channel_owned) {
                    state->finishReadLocked();
                    co_return;
                }
                read = stream.InputStream().ReadAsync(buffer, buffer.Capacity(), InputStreamOptions::Partial);
            }
            auto received = co_await read;
            if (received.Length() == 0) {
                std::lock_guard lock(state->mutex);
                state->finishReadLocked(1);
                co_return;
            }
            state->deliver(received.data(), received.Length(), nullptr, 0);
        }
    } catch (...) {
        std::lock_guard lock(state->mutex);
        state->finishReadLocked(to_hresult().value);
    }
}

IAsyncAction Socket::WriteQueued(std::shared_ptr<State> state,
    DatagramSocket datagram, StreamSocket stream) {
    try {
        for (;;) {
            State::WriteRequest request;
            {
                std::lock_guard lock(state->mutex);
                if (state->write_status.load()) {
                    state->writes.clear();
                    co_return;
                }
                request = std::move(state->writes.front());
            }
            IOutputStream output{nullptr};
            if (request.host) {
                output = co_await datagram.GetOutputStreamAsync(request.host, request.service);
            } else {
                output = stream ? stream.OutputStream() : datagram.OutputStream();
            }
            // UDP remains one datagram. TCP retries only an unwritten suffix.
            auto &buffer = request.buffer;
            for (;;) {
                const auto written = co_await output.WriteAsync(buffer);
                if (written == buffer.Length()) break;
                if (datagram || !written || written > buffer.Length())
                    throw hresult_error(HRESULT_FROM_WIN32(ERROR_WRITE_FAULT));
                Buffer remaining{buffer.Length() - written};
                remaining.Length(remaining.Capacity());
                memcpy(remaining.data(), buffer.data() + written, remaining.Length());
                buffer = std::move(remaining);
            }
            std::lock_guard lock(state->mutex);
            ++state->sent;
            state->writes.pop_front();
            if (state->writes.empty()) co_return;
        }
    } catch (...) {
        std::lock_guard lock(state->mutex);
        const auto error = to_hresult().value;
        state->writes.clear();
        int32_t status = 0;
        if (state->write_status.compare_exchange_strong(status, error))
            state->deliverLocked(nullptr, 0, nullptr, error);
    }
}

void Socket::RegisterDatagram() {
    const auto state = state_;
    // WinRT requires registration before bind/connect. Attach only changes
    // the consumer; the OS handler remains registered until the socket closes.
    receive_registration_ = datagram_.MessageReceived(auto_revoke,
        [state, unconnected = unconnected_, ipv4 = accepts_ipv4_, ipv6 = accepts_ipv6_](
            DatagramSocket const &, DatagramSocketMessageReceivedEventArgs const &args) {
            try {
                const auto family = args.RemoteAddress().Type();
                if ((family == HostNameType::Ipv4 && !ipv4) ||
                    (family == HostNameType::Ipv6 && !ipv6)) return;
                auto reader = args.GetDataReader();
                const auto buffer = reader.ReadBuffer(reader.UnconsumedBufferLength());
                winrt_socket_address source{};
                if (unconnected) source = ParseAddress(args.RemoteAddress(), args.RemotePort());
                state->deliver(buffer.data(), buffer.Length(),
                    unconnected ? &source : nullptr, 0);
            } catch (...) {
                state->deliver(nullptr, 0, nullptr, to_hresult().value);
            }
        });
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
