// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
namespace Partout { class Socket; }
extern "C" {
#endif

/* The available protocols. */
typedef enum { WinrtSocketProtoTCP, WinrtSocketProtoUDP } winrt_socket_proto;

/* The opaque socket type. */
#ifdef __cplusplus
typedef Partout::Socket *winrt_socket;
#else
typedef struct __winrt_socket_struct *winrt_socket;
#endif

/* Close the owned socket and free the wrapper. */
void winrt_socket_free(winrt_socket socket);

/* Create the transport before configuring and opening it. */
winrt_socket winrt_socket_create(winrt_socket_proto proto, bool unconnected);

typedef struct {
    bool dual_stack;
    int timeout_ms;
} winrt_socket_open_options;

/* Configure the transport before calling open. Connected opens are bounded by
 * timeout_ms; unconnected UDP binds a numeric local endpoint. */
bool winrt_socket_open(winrt_socket socket, const char *host, uint16_t port,
    const winrt_socket_open_options *options);

/* Numeric endpoint. family is 4 or 6; port and scope_id are host endian. */
typedef struct {
    uint8_t address[16];
    uint32_t scope_id;
    uint16_t port;
    uint8_t family;
} winrt_socket_address;

/* Worker-thread callbacks are serialized per socket. Buffers and source are
 * borrowed until return; only unconnected UDP supplies source. Error is zero
 * for data, 1 for TCP EOF, otherwise an HRESULT. False pauses packet delivery.
 * Register on attach, clear on detach; replacing a callback is rejected.
 * Clearing drains callbacks. Callbacks must not reenter socket APIs. Keep context
 * alive until cleared. TCP delivers stream chunks, without application framing. */
typedef bool (*winrt_socket_on_receive)(void *context, const uint8_t *bytes,
    size_t length, const winrt_socket_address *source, int32_t error);

bool winrt_socket_set_on_receive(winrt_socket socket, winrt_socket_on_receive callback, void *context);

/* Resume paused delivery without restoring a cleared callback. */
bool winrt_socket_resume_reading(winrt_socket socket);

/* Serialized synchronous completion of WriteAsync; writes one whole datagram
 * or all stream bytes. Returns zero or HRESULT. Unconnected UDP needs destination. */
int32_t winrt_socket_write(winrt_socket socket, const uint8_t *bytes, size_t length,
    const winrt_socket_address *destination);

/* Reject queued/future writes with E_ABORT; an already admitted write may finish. */
void winrt_socket_stop_writes(winrt_socket socket);

/* Returns the bound/connected local endpoint, including the assigned local port. */
bool winrt_socket_get_address(winrt_socket socket, winrt_socket_address *address);

#ifdef __cplusplus
}

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <functional>
#include <memory>

struct SocketApartment;
struct SocketReceiveState;

namespace Partout {

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

    // Stop/drain direct reads before StartWithMainTransport takes receive ownership.
    void TakeOver();

    // After channel startup, send encapsulated packets through its send-buffer pool.
    void SetChannelWriter(std::function<int32_t(const uint8_t *, size_t)> writer);

private:
    void RegisterDatagram();

    // Keep the MTA alive until transports and outstanding callbacks are released.
    std::shared_ptr<SocketApartment> apartment_;
    winrt::Windows::Networking::Sockets::DatagramSocket datagram_{nullptr};
    winrt::Windows::Networking::Sockets::StreamSocket stream_{nullptr};
    winrt::event_token receive_token_{};
    bool receiving_ = false;
    std::shared_ptr<SocketReceiveState> receive_state_;
    bool unconnected_ = false;
    winrt::Windows::Networking::Connectivity::NetworkAdapter adapter_{nullptr};
    winrt::Windows::Networking::HostName bound_host_{nullptr};
    // Wildcard binds can be broader than the requested receive family policy.
    bool accepts_ipv4_ = true;
    bool accepts_ipv6_ = true;
};

} // namespace Partout

#endif
