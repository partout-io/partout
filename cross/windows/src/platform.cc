// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "abi.h"
#include "loop.h"
#include "tun.h"
#include "winrt/log.h"

#include "partout_winrt.h"

namespace Partout {
partout_controller_functions ControllerFunctions() {

    partout_controller_functions functions{};
    functions.set_delegate = [](void *raw, const partout_controller_delegate *delegate) {
        auto controller = static_cast<Partout::TunnelController *>(raw);
        if (!controller) return;
        if (!delegate) {
            controller->Monitor().Stop();
            return;
        }
        controller->Monitor().Start([callbacks = *delegate](bool reachable, bool changed) {
            winrt_log(WinrtLogInfo, "Partout: physical network changed: reachable=%s, refresh=%s",
                      reachable ? "true" : "false", changed ? "true" : "false");
            const partout_reachability info{reachable};
            if (callbacks.on_reachability) callbacks.on_reachability(callbacks.ctx, &info);
            // Notify the daemon that the available physical path has changed.
            if (changed && reachable && callbacks.on_better_path) callbacks.on_better_path(callbacks.ctx);
        });
    };
    functions.set_tunnel = [](void *raw, const char *, const char *json) -> partout_tun {
        auto controller = static_cast<Partout::TunnelController *>(raw);
        if (!controller) return nullptr;
        try {
            auto &loop = controller->Loop();
            // TUN commit and StartWithMainTransport serialize with all socket I/O.
            return loop.Perform([controller, json, &loop]() -> partout_tun {
                auto tun = controller->Open(json);
                if (!tun) return nullptr;
                return reinterpret_cast<partout_tun>(Partout::ABI::WrapTun(loop, std::move(tun)));
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
    functions.configure_sockets = [](void *raw, const partout_reachability *, const partout_socket_descriptor *tokens, size_t count) {
        if (count && !tokens) return false;
        auto controller = static_cast<TunnelController *>(raw);
        for (size_t i = 0; i < count; ++i) {
            if (!ABI::ConfigureSocket(controller, tokens[i])) return false;
        }
        return true;
    };
    return functions;
}
}
