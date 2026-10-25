// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include "socket.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    void *context;
    void (*on_reachability)(void *context, bool reachable);
    void (*on_better_path)(void *context);
} winrt_tun_ctrl_delegate;
/* Delegate records are borrowed during registration; implementations copy them.
 * Contexts are borrowed until cleared. Unregistering must drain callbacks.
 * Reachability notifications are currently unimplemented. */
void winrt_tun_ctrl_set_delegate(void *controller, const winrt_tun_ctrl_delegate *delegate);
bool winrt_tun_ctrl_configure_sockets(void *controller, const winrt_socket *sockets, size_t count);
/* Starts the channel with negotiated settings and returns an owned TUN handle. */
typedef struct WinrtTunHandle *winrt_tun;
typedef bool (*winrt_tun_on_receive)(void *context, const uint8_t *bytes, size_t length);
winrt_tun winrt_tun_ctrl_set_tunnel(void *controller, const char *uuid, const char *info_json);
void winrt_tun_free(winrt_tun tun);
/* Clearing drains delivery. Callbacks only enqueue borrowed input. */
bool winrt_tun_set_on_receive(winrt_tun tun, winrt_tun_on_receive callback, void *context);
void winrt_tun_stop_writes(winrt_tun tun);
/* Copies one IP packet into the channel receive pool and appends/flushes it. */
int32_t winrt_tun_write(winrt_tun tun, const uint8_t *bytes, size_t length);
void winrt_tun_ctrl_report_snapshot(void *controller, const char *snapshot_json);
void winrt_tun_ctrl_set_environment_value(void *controller, const char *key, const char *value);
void winrt_tun_ctrl_clear_tunnel(void *controller, bool kill_switch);
void winrt_tun_ctrl_cancel_tunnel(void *controller, const char *error_message);
#ifdef __cplusplus
}

#include <winrt/Windows.Networking.Vpn.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <functional>
#include <memory>
#include <mutex>

struct WinrtTun;
struct WinrtPacketCounters;

namespace Partout {

// Internal platform ref. Daemon bindings retain the channel until callbacks drain.
class TunnelController {
public:
    explicit TunnelController(winrt::Windows::Networking::Vpn::VpnChannel const &channel);
    ~TunnelController();
    TunnelController(const TunnelController &) = delete;
    TunnelController &operator=(const TunnelController &) = delete;

    bool Associate(Socket *socket) noexcept;
    bool Start(const char *info_json) noexcept;
    void Stop() noexcept;
    winrt_tun Open(const char *info_json);
    void Encapsulate(winrt::Windows::Networking::Vpn::VpnPacketBufferList const &packets);
    void Decapsulate(winrt::Windows::Networking::Vpn::VpnPacketBuffer const &packet);

private:
    winrt::Windows::Networking::Vpn::VpnChannel channel_;
    winrt::Windows::Foundation::IInspectable transport_{nullptr};
    winrt::Windows::Networking::Sockets::DatagramSocket idle_transport_{nullptr};
    winrt::Windows::Networking::Connectivity::NetworkAdapter udp_adapter_{nullptr};
    bool started_ = false;
    Socket *socket_ = nullptr; // Borrowed until Start; the link owns it.
    std::shared_ptr<WinrtTun> tun_;
    std::shared_ptr<WinrtPacketCounters> counters_;
    std::function<void(const uint8_t *, size_t)> link_receive_;
    std::mutex input_mutex_; // Protects snapshots used by plugin callbacks.
};
} // namespace Partout

#endif
