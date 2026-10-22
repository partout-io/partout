// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include "winrt/socket.h"
#include "winrt/log.h"
#include <winrt/Windows.Networking.Sockets.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Networking.h>
#include <chrono>
#include <atomic>
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
    std::atomic<bool> writes_stopped{false};
    winrt_socket_on_receive callback = nullptr;
    void *context = nullptr;
    bool reading = false;
    bool paused = false;

    void deliver(const uint8_t *bytes, size_t size,
                 const winrt_socket_address *source, int32_t error) {
        std::lock_guard lock(mutex);
        deliverLocked(bytes, size, source, error);
    }

    void deliverLocked(const uint8_t *bytes, size_t size,
                       const winrt_socket_address *source, int32_t error) {
        if (!callback || (paused && !error)) return;
        paused = !callback(context, bytes, size, source, error);
    }
};

struct WinrtSocket {
    // Keep the MTA alive until transports and outstanding callbacks are released.
    std::shared_ptr<SocketApartment> apartment;
    winrt::Windows::Networking::Sockets::DatagramSocket datagram{nullptr};
    winrt::Windows::Networking::Sockets::StreamSocket stream{nullptr};
    winrt::event_token receive_token{};
    bool receiving = false;
    std::shared_ptr<SocketReceiveState> receive_state;
    bool unconnected = false;
    HostName bound_host{nullptr};
    // WinRT wildcard binds can listen on both families. The receive path must
    // retain the requested family policy even when the OS bind is broader.
    bool accepts_ipv4 = true;
    bool accepts_ipv6 = true;

    winrt::Windows::Foundation::IInspectable transport() const {
        if (datagram) return datagram;
        return stream;
    }

    ~WinrtSocket() noexcept;
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
    winrt_socket_address result{};
    if (!host || (host.Type() != HostNameType::Ipv4 && host.Type() != HostNameType::Ipv6))
        throw hresult_invalid_argument();
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
            {
                std::lock_guard lock(state->mutex);
                if (!state->callback || state->paused) { state->reading = false; co_return; }
            }
            auto received = co_await stream.InputStream().ReadAsync(
                buffer, buffer.Capacity(), InputStreamOptions::Partial);
            if (received.Length() == 0) {
                std::lock_guard lock(state->mutex);
                state->reading = false;
                state->deliverLocked(nullptr, 0, nullptr, 1);
                co_return;
            }
            state->deliver(received.data(), received.Length(), nullptr, 0);
        }
    } catch (...) {
        std::lock_guard lock(state->mutex);
        state->reading = false;
        state->deliverLocked(nullptr, 0, nullptr, to_hresult().value);
    }
}

void register_datagram(WinrtSocket &socket, bool unconnected) {
    const auto state = socket.receive_state;
    // WinRT requires registration before bind/connect. Attach only changes
    // the consumer; the OS handler remains registered until the socket closes.
    socket.receive_token = socket.datagram.MessageReceived(
        [state, unconnected, ipv4 = socket.accepts_ipv4, ipv6 = socket.accepts_ipv6](
            DatagramSocket const &, DatagramSocketMessageReceivedEventArgs const &args) {
            try {
                const auto family = args.RemoteAddress().Type();
                if ((family == HostNameType::Ipv4 && !ipv4) ||
                    (family == HostNameType::Ipv6 && !ipv6)) return;
                auto reader = args.GetDataReader();
                const auto buffer = reader.ReadBuffer(reader.UnconsumedBufferLength());
                winrt_socket_address source{};
                if (unconnected) source = socket_address(args.RemoteAddress(), args.RemotePort());
                state->deliver(buffer.data(), buffer.Length(),
                    unconnected ? &source : nullptr, 0);
            } catch (...) {
                state->deliver(nullptr, 0, nullptr, to_hresult().value);
            }
        });
    socket.receiving = true;
}

} // namespace

WinrtSocket::~WinrtSocket() noexcept {
    winrt_socket_set_on_receive(this, nullptr, nullptr);
    // Each cleanup is independent, so a failed event revocation cannot skip Close.
    try { if (datagram && receiving) datagram.MessageReceived(receive_token); } catch (...) {}
    try { if (datagram) datagram.Close(); } catch (...) {}
    try { if (stream) stream.Close(); } catch (...) {}
}

IInspectable winrt_socket_transport(winrt_socket socket) {
    return socket ? socket->transport() : nullptr;
}

extern "C" {

winrt_socket winrt_socket_create(winrt_socket_proto proto) {
    try {
        Apartment apartment;
        auto socket = std::make_unique<WinrtSocket>();
        socket->apartment = std::make_shared<SocketApartment>();
        socket->receive_state = std::make_shared<SocketReceiveState>();
        socket->receive_state->apartment = socket->apartment;
        if (proto == WinrtSocketProtoUDP) socket->datagram = DatagramSocket{};
        else if (proto == WinrtSocketProtoTCP) socket->stream = StreamSocket{};
        else throw hresult_invalid_argument();
        return socket.release();
    } catch (...) {
        winrt_log(WinrtLogError, "winrt_socket_create failed: HRESULT 0x%08x",
            static_cast<unsigned int>(to_hresult().value));
        return nullptr;
    }
}

bool winrt_socket_open(winrt_socket socket, const char *hostname, uint16_t port,
                           const winrt_socket_open_options *options) {
    try {
        if (!socket || !hostname || !*hostname || !options || options->timeout_ms < 0 ||
            (options->unconnected && !socket->datagram) ||
            (options->dual_stack && !options->unconnected)) {
            throw hresult_invalid_argument();
        }
        Apartment apartment;
        const HostName host{to_hstring(hostname)};
        const bool numeric = host.Type() == HostNameType::Ipv4 || host.Type() == HostNameType::Ipv6;
        if ((options->unconnected && !numeric) ||
            (options->dual_stack && host.Type() != HostNameType::Ipv6)) {
            throw hresult_invalid_argument();
        }
        const auto service = to_hstring(port);
        socket->unconnected = options->unconnected;
        if (options->unconnected) {
            socket->accepts_ipv4 = host.Type() == HostNameType::Ipv4 || options->dual_stack;
            socket->accepts_ipv6 = host.Type() == HostNameType::Ipv6;
        }
        if (socket->datagram) {
            register_datagram(*socket, options->unconnected);
        }
        if (options->unconnected) {
            // WinRT rejects 0.0.0.0 as a BindEndpointAsync hostname. A service
            // bind covers all interfaces; the receive handler enforces family
            // policy because WinRT exposes no IPV6_V6ONLY control.
            const bool ipv4_wildcard = host.CanonicalName() == L"0.0.0.0";
            const bool ipv6_wildcard = host.CanonicalName() == L"::";
            const auto local_service = port == 0 ? hstring{} : service;
            if (ipv4_wildcard || (options->dual_stack && ipv6_wildcard)) {
                socket->datagram.BindServiceNameAsync(local_service).get();
            } else {
                socket->datagram.BindEndpointAsync(host, local_service).get();
            }
            socket->bound_host = host;
        } else if (socket->datagram) {
            wait_for_connect(socket->datagram.ConnectAsync(host, service), options->timeout_ms);
        } else {
            wait_for_connect(socket->stream.ConnectAsync(host, service, SocketProtectionLevel::PlainSocket),
                options->timeout_ms);
        }
        winrt_log(WinrtLogDebug, "WinRT socket: Opened %s %s:%u, mode=%s, dual_stack=%s",
            socket->datagram ? "UDP" : "TCP", hostname, static_cast<unsigned int>(port),
            options->unconnected ? "unconnected (bound)" : "connected",
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

bool winrt_socket_get_address(winrt_socket socket, winrt_socket_address *address) {
    try {
        if (!socket || !address) throw hresult_invalid_argument();
        Apartment apartment;
        HostName host{nullptr};
        hstring port;
        if (socket->datagram) {
            const auto info = socket->datagram.Information();
            host = info.LocalAddress();
            port = info.LocalPort();
            // Service binds may report :: even for our IPv4-only policy.
            // Preserve the requested binding while using the OS-assigned port.
            if (socket->bound_host) host = socket->bound_host;
        } else if (socket->stream) {
            const auto info = socket->stream.Information();
            host = info.LocalAddress();
            port = info.LocalPort();
        }
        *address = socket_address(host, port);
        return true;
    } catch (...) {
        return false;
    }
}

void winrt_socket_free(winrt_socket socket) {
    delete socket;
}

int32_t winrt_socket_write(winrt_socket socket, const uint8_t *bytes, size_t length,
    const winrt_socket_address *destination) {
    try {
        if (!socket || (!bytes && length) || length > UINT32_MAX)
            throw hresult_invalid_argument();
        Apartment apartment;
        const auto state = socket->receive_state;
        const auto stream = socket->stream;
        const auto datagram = socket->datagram;
        const bool unconnected = socket->unconnected;
        const bool ipv4 = socket->accepts_ipv4, ipv6 = socket->accepts_ipv6;
        // Retain transports and the lock independently of wrapper destruction.
        std::lock_guard lock(state->write_mutex);
        if (state->writes_stopped.load()) return E_ABORT;
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
        return 0;
    } catch (...) {
        return to_hresult().value;
    }
}

void winrt_socket_stop_writes(winrt_socket socket) {
    socket->receive_state->writes_stopped.store(true);
}

bool winrt_socket_set_on_receive(winrt_socket socket,
    winrt_socket_on_receive callback, void *context) {
    if (!socket || !socket->receive_state) return false;
    const auto state = socket->receive_state;
    try {
        bool start_read;
        {
            std::lock_guard lock(state->mutex);
            if (callback && state->callback) return false;
            state->callback = callback;
            state->context = context;
            state->paused = false;
            start_read = callback && socket->stream && !state->reading;
            if (start_read) state->reading = true;
        }
        if (start_read) read_stream(state, socket->stream);
        return true;
    } catch (...) {
        std::lock_guard lock(state->mutex);
        state->callback = nullptr;
        state->context = nullptr;
        state->reading = false;
        return false;
    }
}

bool winrt_socket_resume_reading(winrt_socket socket) {
    if (!socket || !socket->receive_state) return false;
    const auto state = socket->receive_state;
    try {
        bool start_read;
        {
            std::lock_guard lock(state->mutex);
            // Resume must never restore a cleared context.
            if (!state->callback) return false;
            state->paused = false;
            start_read = socket->stream && !state->reading;
            if (start_read) state->reading = true;
        }
        if (start_read) read_stream(state, socket->stream);
        return true;
    } catch (...) {
        std::lock_guard lock(state->mutex);
        state->reading = false;
        state->deliverLocked(nullptr, 0, nullptr, to_hresult().value);
        return false;
    }
}

}
