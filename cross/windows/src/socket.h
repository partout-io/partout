// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once

#include "winrt/socket.h"
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <functional>
#include <memory>

namespace Partout {

// Callers serialize writes with other writes, open/configuration, channel
// takeover, and destruction. Keep the socket alive until
// all calls return. StopWrites and receive callback management may overlap Write.
class Socket {
public:
    using Receiver = std::function<void(const uint8_t *, size_t)>;
    using Writer = std::function<int32_t(const uint8_t *, size_t)>;

    Socket(winrt_socket_proto proto, bool unconnected);
    ~Socket() noexcept;
    Socket(const Socket &) = delete;
    Socket &operator=(const Socket &) = delete;

    // Borrow the transport for VPN channel association; no socket internals escape.
    winrt::Windows::Foundation::IInspectable Transport() const;

    // Whether the socket uses application-owned, unconnected UDP.
    bool IsUnconnected() const;

    // Before open: constrain independent UDP to the selected physical adapter.
    void SetAdapter(winrt::Windows::Networking::Connectivity::NetworkAdapter const &adapter);

    bool Open(const char *hostname, uint16_t port, const winrt_socket_open_options *options);
    bool GetAddress(winrt_socket_address *address);
    bool SetOnReceive(winrt_socket_on_receive callback, void *context);
    bool ResumeReading();
    int32_t Write(const uint8_t *bytes, size_t length, const winrt_socket_address *destination);
    void StopWrites();

    // Drain direct I/O and install the channel writer. Store the returned receiver
    // before starting the channel; it retains state and is safe after link detach.
    Receiver TakeOver(Writer writer);

private:
    struct State;

    void RegisterForDatagrams();
    static void WaitForConnect(winrt::Windows::Foundation::IAsyncAction const &action, int timeout_ms);
    static winrt_socket_address ParseAddress(winrt::Windows::Networking::HostName const &host,
        winrt::hstring const &port);
    static winrt::Windows::Foundation::IAsyncAction ReadStream(std::shared_ptr<State> state,
        winrt::Windows::Networking::Sockets::StreamSocket stream);
    void EnqueueWrite(const uint8_t *bytes, size_t length, const winrt_socket_address *destination);
    static winrt::Windows::Foundation::IAsyncAction WriteQueued(std::shared_ptr<State> state,
        winrt::Windows::Networking::Sockets::DatagramSocket datagram,
        winrt::Windows::Networking::Sockets::StreamSocket stream);

    // Keep the MTA alive until transports and outstanding callbacks are released.
    std::shared_ptr<State> state_;
    winrt::Windows::Networking::Sockets::DatagramSocket datagram_{nullptr};
    winrt::Windows::Networking::Sockets::StreamSocket stream_{nullptr};
    winrt::Windows::Foundation::IAsyncAction read_{nullptr};
    winrt::Windows::Foundation::IAsyncAction write_{nullptr};
    winrt::Windows::Networking::Sockets::DatagramSocket::MessageReceived_revoker receive_registration_;
    Writer channel_write_; // Installed by TakeOver; empty during direct socket I/O.
    bool unconnected_ = false;
    winrt::Windows::Networking::Connectivity::NetworkAdapter adapter_{nullptr};
    winrt::Windows::Networking::HostName bound_host_{nullptr};
    // Wildcard binds can be broader than the requested receive family policy.
    bool accepts_ipv4_ = true;
    bool accepts_ipv6_ = true;
};

} // namespace Partout

// Owned C handle; the socket stays private to the native implementation.
struct __winrt_socket_struct {
    Partout::Socket handle;
};
