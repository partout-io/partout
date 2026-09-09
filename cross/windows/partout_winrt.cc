// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <windows.h>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include "partout_winrt.h"
#include "portable/tun_ctrl_winrt.h"

// Forces this archive member, including its C++ exports, into partout.dll.
extern "C" void pp_winrt_runtime_link() {}

using namespace winrt;
using namespace winrt::Windows::Networking::Vpn;

struct PartoutVpnChannelRuntime::Impl {
    VpnChannel channel;
    std::string profile;
    std::string cache_dir;
    partout_init_args init_args;
    partout_daemon_options options;
    bool daemon_started = false;
    enum class StartupStatus { waiting, connecting, connected, failed };
    std::mutex startup_mutex;
    std::condition_variable startup_changed;
    StartupStatus startup_status = StartupStatus::waiting;

    // Called by the daemon, including during partout_daemon_start(). Only
    // publish state here: stopping the daemon from its callback would deadlock.
    void OnConnectionStatus(const char *status) noexcept {
        if (!status) return;
        std::scoped_lock lock(startup_mutex);
        if (startup_status == StartupStatus::connected ||
            startup_status == StartupStatus::failed) return;
        const std::string_view value{status};
        if (value == "connecting") {
            startup_status = StartupStatus::connecting;
        } else if (value == "connected") {
            startup_status = StartupStatus::connected;
        } else if (value == "disconnected" &&
                   startup_status == StartupStatus::connecting) {
            startup_status = StartupStatus::failed;
        }
        // The daemon emits an initial disconnected status before connecting.
        startup_changed.notify_all();
    }

    void WaitForConnection() {
        std::unique_lock lock(startup_mutex);
        const bool completed = startup_changed.wait_for(lock, std::chrono::seconds(60), [this] {
            return startup_status == StartupStatus::connected ||
                startup_status == StartupStatus::failed;
        });
        if (!completed) {
            throw hresult_error(HRESULT_FROM_WIN32(ERROR_TIMEOUT), L"Partout connection timed out");
        }
        if (startup_status == StartupStatus::failed) {
            throw hresult_error(E_FAIL, L"Partout disconnected during startup");
        }
    }

    Impl(VpnChannel const &value, const char *profile_json,
         const partout_init_args &initialization, const partout_daemon_options &daemon_options)
        : channel(value), profile(profile_json ? profile_json : ""),
          cache_dir(daemon_options.cache_dir ? daemon_options.cache_dir : ""),
          init_args(initialization), options(daemon_options) {
        if (!channel || profile.empty() || options.is_daemon) {
            throw hresult_invalid_argument();
        }
        options.cache_dir = daemon_options.cache_dir ? cache_dir.c_str() : nullptr;
    }

    ~Impl() { Stop(); }

    void CheckChannel(VpnChannel const &value) const {
        if (!value || value != channel) throw hresult_invalid_argument();
    }

    // FIXME: ###, Retain log level
    void Log(std::wstring_view message) const noexcept {
        try { channel.LogDiagnosticMessage(hstring{message}); } catch (...) {}
        try {
            if (init_args.logger_fn) {
                const auto text = to_string(hstring{message});
                init_args.logger_fn(init_args.logger_ctx, PartoutLogLevelDebug, text.c_str());
            }
        } catch (...) {}
    }

    void Stop() noexcept {
        // Stop drains callbacks and releases their internal controller before
        // the runtime releases its channel or transport.
        if (daemon_started) {
            partout_daemon_stop();
            daemon_started = false;
        }
    }

    void Connect() {
        Stop();
        {
            std::scoped_lock lock(startup_mutex);
            startup_status = StartupStatus::waiting;
        }
        Log(L"PartoutVpnChannelRuntime.Connect entered");
        partout_init(&init_args);
        try {
            partout_daemon_start_args args{};
            args.profile = profile.c_str();
            args.options = options;
            partout_daemon_bindings bindings{};
            bindings.controller = new PartoutTunnelController{channel};
            // Impl outlives the daemon; Stop() drains callbacks before destruction.
            bindings.events.ctx = this;
            bindings.events.set_connection_status = [](void *ctx, const char *status) noexcept {
                static_cast<Impl *>(ctx)->OnConnectionStatus(status);
            };
            bindings.release = [](partout_daemon_bindings *owned) noexcept {
                delete static_cast<PartoutTunnelController *>(owned->controller);
                owned->controller = nullptr;
            };
            args.bindings = &bindings;
            // The C ABI consumes the bindings even if startup fails.
            if (partout_daemon_start(&args) != PartoutCompletionCodeOK) {
                throw hresult_error(E_FAIL, L"Unable to start Partout daemon");
            }
            daemon_started = true;
            Log(L"PartoutVpnChannelRuntime: Waiting for connection status");
            WaitForConnection();
            Log(L"PartoutVpnChannelRuntime: Connection established");
        } catch (...) {
            const auto failure = to_hresult();
            pp_clog_v(PPLogLevelError, "PartoutVpnChannelRuntime.Connect failed: HRESULT 0x%08x",
                static_cast<unsigned int>(failure.value));
            Stop();
            Log(L"PartoutVpnChannelRuntime.Connect failed");
            try { channel.SetErrorMessage(L"Unable to start Partout VPN channel"); } catch (...) {}
            throw;
        }
    }
};

PartoutVpnChannelRuntime::PartoutVpnChannelRuntime(
    VpnChannel const &channel,
    const char *profile,
    const partout_init_args &init_args,
    const partout_daemon_options &options
) : impl_(std::make_unique<Impl>(channel, profile, init_args, options)) {
}

PartoutVpnChannelRuntime::~PartoutVpnChannelRuntime() = default;

void PartoutVpnChannelRuntime::Connect(VpnChannel const &channel) {
    impl_->CheckChannel(channel);
    impl_->Connect();
}

void PartoutVpnChannelRuntime::Disconnect(VpnChannel const &channel) {
    impl_->CheckChannel(channel);
    impl_->Log(L"PartoutVpnChannelRuntime.Disconnect entered");
    impl_->Stop();
}

void PartoutVpnChannelRuntime::GetKeepAlivePayload(
    VpnChannel const &channel,
    VpnPacketBuffer &keep_alive_packet
) {
    impl_->CheckChannel(channel);
    keep_alive_packet = nullptr;
    impl_->Log(L"PartoutVpnChannelRuntime.GetKeepAlivePayload entered (no payload)");
}

void PartoutVpnChannelRuntime::Encapsulate(
    VpnChannel const &channel, VpnPacketBufferList const &packets,
    VpnPacketBufferList const &encapsulated_packets
) {
    impl_->CheckChannel(channel);
    (void)encapsulated_packets;
    // Input buffers stay in the platform-owned list, as in the original plugin.
    impl_->Log(L"PartoutVpnChannelRuntime.Encapsulate entered: " +
        std::to_wstring(packets.Size()) + L" packet(s)");
}

void PartoutVpnChannelRuntime::Decapsulate(
    VpnChannel const &channel,
    VpnPacketBuffer const &packet,
    VpnPacketBufferList const &decapsulated_packets,
    VpnPacketBufferList const &control_packets
) {
    impl_->CheckChannel(channel);
    (void)packet;
    (void)decapsulated_packets;
    (void)control_packets;
    impl_->Log(L"PartoutVpnChannelRuntime.Decapsulate entered (payload ignored)");
}
