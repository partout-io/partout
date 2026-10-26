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
// takeover, writer replacement, and destruction. Keep the socket alive until
// all calls return. StopWrites and receive callback management may overlap Write.
class Socket {
public:
    Socket(winrt_socket_proto proto, bool unconnected);
    ~Socket() noexcept;
    Socket(const Socket &) = delete;
    Socket &operator=(const Socket &) = delete;

    bool Open(const char *hostname, uint16_t port, const winrt_socket_open_options *options);
    bool SetOnReceive(winrt_socket_on_receive callback, void *context);
    bool ResumeReading();
    int32_t Write(const uint8_t *bytes, size_t length, const winrt_socket_address *destination);
    void StopWrites();
    bool GetAddress(winrt_socket_address *address);

    // Borrow the transport for VPN channel association; no socket internals escape.
    winrt::Windows::Foundation::IInspectable Transport() const;

    // Whether the socket uses application-owned, unconnected UDP.
    bool IsUnconnected() const;

    // Before open: constrain independent UDP to the selected physical adapter.
    void SetAdapter(winrt::Windows::Networking::Connectivity::NetworkAdapter const &adapter);

    // Retains callback state, not the socket wrapper. Safe after link detach.
    std::function<void(const uint8_t *, size_t)> ChannelReceiver() const;

    // Drain direct writes, then stop reads before channel transport takeover.
    void TakeOver();

    // After channel startup, send encapsulated packets through its send-buffer pool.
    void SetChannelWriter(std::function<int32_t(const uint8_t *, size_t)> writer);

private:
    struct State;

    static void WaitForConnect(winrt::Windows::Foundation::IAsyncAction const &action, int timeout_ms);
    static winrt_socket_address ParseAddress(winrt::Windows::Networking::HostName const &host,
        winrt::hstring const &port);
    static winrt::Windows::Foundation::IAsyncAction ReadStream(std::shared_ptr<State> state,
        winrt::Windows::Networking::Sockets::StreamSocket stream);
    static winrt::Windows::Foundation::IAsyncAction WriteQueued(std::shared_ptr<State> state,
        winrt::Windows::Networking::Sockets::DatagramSocket datagram,
        winrt::Windows::Networking::Sockets::StreamSocket stream);
    bool StartReading();
    void RegisterDatagram();

    // Keep the MTA alive until transports and outstanding callbacks are released.
    std::shared_ptr<State> state_;
    winrt::Windows::Networking::Sockets::DatagramSocket datagram_{nullptr};
    winrt::Windows::Networking::Sockets::StreamSocket stream_{nullptr};
    winrt::Windows::Foundation::IAsyncAction read_{nullptr};
    winrt::Windows::Foundation::IAsyncAction write_{nullptr};
    winrt::Windows::Networking::Sockets::DatagramSocket::MessageReceived_revoker receive_registration_;
    std::function<int32_t(const uint8_t *, size_t)> channel_write_;
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
