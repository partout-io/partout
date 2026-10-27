// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "abi.h"
#include "loop.h"
#include "tun.h"
#include "winrt/log.h"

// Partout integration belongs here; the native backend has no portable headers.
#if defined(_MSC_VER) && !defined(__clang__)
#pragma warning(push)
#pragma warning(disable : 4068)
#define _Nullable
#define _Nonnull
#endif
extern "C" {
#include "portable/tun.h"
#include "portable/tun_ctrl.h"
#include "portable/socket.h"
}
#if defined(_MSC_VER) && !defined(__clang__)
#undef _Nonnull
#undef _Nullable
#pragma warning(pop)
#endif

static_assert(sizeof(pp_socket_address) == sizeof(winrt_address));
static_assert(offsetof(pp_socket_address, family) == offsetof(winrt_address, family));

extern "C" {
void pp_tun_free(pp_tun raw) {
    if (auto transport = reinterpret_cast<winrt_transport *>(raw))
        transport->release(transport->context);
}

pp_socket_configurator pp_socket_configurator_current(void *ref) {
    return {ref, [](void *raw, const pp_reachability *, const pp_socket_fd *tokens, size_t count) {
                if (count && !tokens) return false;
                auto controller = static_cast<Partout::TunnelController *>(raw);
                for (size_t i = 0; i < count; ++i) {
                    if (!Partout::ABI::ConfigureSocket(controller, tokens[i])) return false;
                }
                return true;
            }};
}

pp_tun_ctrl_fnt pp_tun_ctrl_fnt_current() {
    winrt_set_logger([](winrt_log_level level, const char *message) {
        static const pp_log_level levels[] = {PPLogLevelFault, PPLogLevelError, PPLogLevelNotice,
                                              PPLogLevelInfo, PPLogLevelDebug};
        if (static_cast<unsigned>(level) < std::size(levels)) pp_clog(levels[level], message);
    });
    pp_tun_ctrl_fnt functions{};
    functions.set_delegate = [](void *raw, const pp_tun_ctrl_delegate *delegate) {
        auto controller = static_cast<Partout::TunnelController *>(raw);
        if (!controller) return;
        if (!delegate) {
            controller->Monitor().Stop();
            return;
        }
        controller->Monitor().Start([callbacks = *delegate](bool reachable, bool changed) {
            winrt_log(WinrtLogInfo, "Partout: physical network changed: reachable=%s, refresh=%s",
                      reachable ? "true" : "false", changed ? "true" : "false");
            const pp_reachability info{reachable};
            if (callbacks.on_reachability) callbacks.on_reachability(callbacks.ctx, &info);
            // Notify the daemon that the available physical path has changed.
            if (changed && reachable && callbacks.on_better_path) callbacks.on_better_path(callbacks.ctx);
        });
    };
    functions.set_tunnel = [](void *raw, const char *, const char *json) -> pp_tun {
        auto controller = static_cast<Partout::TunnelController *>(raw);
        if (!controller) return nullptr;
        try {
            auto &loop = controller->Loop();
            // TUN commit and StartWithMainTransport serialize with all socket I/O.
            return loop.Perform([controller, json, &loop]() -> pp_tun {
                auto tun = controller->Open(json);
                if (!tun) return nullptr;
                return reinterpret_cast<pp_tun>(Partout::ABI::WrapTun(loop, std::move(tun)));
            });
        } catch (...) {
            winrt_log(WinrtLogError, "Partout: channel open failed: HRESULT=0x%08x",
                      static_cast<unsigned>(winrt::to_hresult().value));
            return nullptr;
        }
    };
    functions.report_snapshot = [](void *, const char *) {
        // FIXME: ###, Report tunnel snapshots.
    };
    functions.set_environment_value = [](void *, const char *, const char *) {
        // FIXME: ###, Apply environment values.
    };
    functions.clear_tunnel = [](void *raw, bool kill_switch) {
        // FIXME: ###, Implement kill switch support.
        if (kill_switch) winrt_log(WinrtLogNotice, "Partout: kill switch not implemented");
        if (auto controller = static_cast<Partout::TunnelController *>(raw)) controller->Close();
    };
    functions.cancel_tunnel = [](void *, const char *) {
        // FIXME: ###, Cancel the tunnel connection.
    };
    return functions;
}
}
