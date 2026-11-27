// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <windows.h>
#include <chrono>
#include <condition_variable>
#include <cwchar>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.h>
#include <partout/extensions/ProfileExtensions.h>
#include <partout/winrt/VpnChannelRuntime.h>
#include <partout.h>
#include "backend/Log.h"
#include "backend/ABI.h"
#include "backend/Platform.h"
#include "backend/TunnelController.h"
#include "backend/RuntimeLoop.h"

#include <partout/models/ConnectionStatus.h>

using namespace winrt;
using namespace winrt::Windows::Networking::Vpn;

namespace Partout {
struct VpnChannelRuntime::Impl {
    enum class StartupStatus {
        waiting,
        connecting,
        connected,
        failed
    };

    VpnChannel channel;
    std::string profile;
    std::string cache_dir;
    partout_init_args init_args;
    partout_daemon_options options;
    Models::TunnelControllerOptions controller_options;
    std::atomic_bool canceled{false};
    bool daemon_started = false;
    std::unique_ptr<RuntimeLoop> loop;

    // Packet callbacks borrow the controller only while holding this gate.
    // Stop waits for those borrows before destroying native state.
    std::mutex controller_mutex;
    std::unique_ptr<TunnelController> controller;
    std::mutex startup_mutex;
    std::condition_variable startup_changed;
    StartupStatus startup_status = StartupStatus::waiting;

    Impl(VpnChannel const &value, const std::string &profile_json, const Runtime::InitializationOptions &initialization,
         const Runtime::DaemonOptions &daemon_options, Models::TunnelControllerOptions controller_options_value
    );
    ~Impl();

    void Start();
    void Stop() noexcept;
    void WaitForConnection();
    void OnConnectionStatus(const Models::ConnectionStatus &status) noexcept;
    void CheckChannel(VpnChannel const &value) const;
    bool StartupCompleteLocked() const;
    void Log(partout_log_level level, std::wstring_view message) const noexcept;
};

VpnChannelRuntime::VpnChannelRuntime(VpnChannel const &channel,
                                     const std::string &profile,
                                     const Runtime::InitializationOptions &init_args,
                                     const Runtime::DaemonOptions &options,
                                     Models::TunnelControllerOptions controller_options
)
    : impl_(std::make_unique<Impl>(channel, profile, init_args, options, std::move(controller_options))) {}

VpnChannelRuntime::~VpnChannelRuntime() = default;

void VpnChannelRuntime::Connect(VpnChannel const &channel) {
    impl_->CheckChannel(channel);
    impl_->Start();
}

void VpnChannelRuntime::Disconnect(VpnChannel const &channel) {
    impl_->CheckChannel(channel);
    impl_->Log(PartoutLogLevelDebug, L"Partout::VpnChannelRuntime: disconnect requested");
    impl_->Stop();
    impl_->Log(PartoutLogLevelInfo, L"Partout::VpnChannelRuntime: disconnected");
}

void VpnChannelRuntime::Encapsulate(VpnChannel const &channel, VpnPacketBufferList const &packets,
                                    VpnPacketBufferList const &encapsulated_packets) {
    impl_->CheckChannel(channel);
    (void)encapsulated_packets;
    std::lock_guard lock(impl_->controller_mutex);
    if (impl_->controller) impl_->controller->Encapsulate(packets);
}

void VpnChannelRuntime::Decapsulate(VpnChannel const &channel, VpnPacketBuffer const &packet,
                                    VpnPacketBufferList const &decapsulated_packets,
                                    VpnPacketBufferList const &control_packets) {
    impl_->CheckChannel(channel);
    (void)decapsulated_packets;
    (void)control_packets;
    std::lock_guard lock(impl_->controller_mutex);
    if (impl_->controller) impl_->controller->Decapsulate(packet);
}

// FIXME: ###, Windows, Supply the protocol keepalive payload when required.
void VpnChannelRuntime::GetKeepAlivePayload(VpnChannel const &channel,
                                            VpnPacketBuffer &keep_alive_packet) {
    impl_->CheckChannel(channel);
    keep_alive_packet = nullptr;
    impl_->Log(PartoutLogLevelDebug,
               L"Partout::VpnChannelRuntime: keepalive requested: payload=none");
}

void VpnChannelRuntime::Cancel() noexcept {
    impl_->canceled.store(true);
    std::scoped_lock lock(impl_->startup_mutex);
    impl_->startup_status = Impl::StartupStatus::failed;
    impl_->startup_changed.notify_all();
}

// Runtime implementation.

VpnChannelRuntime::Impl::Impl(
    VpnChannel const &value,
    const std::string &profile_json,
    const Runtime::InitializationOptions &initialization,
    const Runtime::DaemonOptions &daemon_options,
    Models::TunnelControllerOptions controller_options_value
)
    : channel(value), profile(profile_json),
      cache_dir(daemon_options.cache_dir.value_or(std::string())),
      init_args{}, options{}, controller_options(std::move(controller_options_value)) {
    if (!channel || profile.empty()) {
        throw hresult_invalid_argument();
    }
    init_args.log_level = static_cast<int>(initialization.log_level);
    init_args.logs_private_data = initialization.logs_private_data;
    init_args.logger_fn = initialization.logger_fn;
    init_args.logger_ctx = initialization.logger_ctx;
    options.starts_immediately = daemon_options.starts_immediately;
    options.cancels_unrecoverable = daemon_options.cancels_unrecoverable;
    options.cache_dir = daemon_options.cache_dir ? cache_dir.c_str() : nullptr;
    options.min_data_count_delta = daemon_options.min_data_count_delta;
    switch (daemon_options.crypto) {
        case Runtime::CryptoBackend::Default: options.crypto = PartoutCryptoDefault; break;
        case Runtime::CryptoBackend::OpenSSL: options.crypto = PartoutCryptoOpenSSL; break;
        case Runtime::CryptoBackend::MbedTLS: options.crypto = PartoutCryptoMbedTLS; break;
        case Runtime::CryptoBackend::Native: options.crypto = PartoutCryptoNative; break;
        default: throw hresult_invalid_argument();
    }
}

VpnChannelRuntime::Impl::~Impl() {
    Stop();
}

void VpnChannelRuntime::Impl::Start() {
    Stop();
    {
        std::scoped_lock lock(startup_mutex);
        if (canceled.load()) throw hresult_canceled();
        startup_status = StartupStatus::waiting;
    }
    Log(PartoutLogLevelDebug, L"Partout::VpnChannelRuntime: connect requested");
    partout_init(&init_args);
    Log::SetLogger(&init_args);
    try {
        const auto prepared = Profile::PrepareInteractive(
            Models::TaggedProfile::FromJson(Json::Parse(profile)),
            [this](bool needs_otp) {
                using winrt::Windows::Foundation::AsyncStatus;
                if (canceled.load()) throw hresult_canceled();
                const auto type = needs_otp ? VpnCredentialType::UsernameOtpPin :
                    VpnCredentialType::UsernamePassword;
                const auto operation = channel.RequestCredentialsAsync(type);
                const auto deadline = std::chrono::steady_clock::now() + VpnChannelRuntime::CredentialPromptTimeout;
                while (operation.Status() == AsyncStatus::Started) {
                    if (canceled.load()) {
                        operation.Cancel();
                        throw hresult_canceled();
                    }
                    if (std::chrono::steady_clock::now() >= deadline) {
                        operation.Cancel();
                        throw hresult_error(HRESULT_FROM_WIN32(ERROR_TIMEOUT));
                    }
                    std::this_thread::sleep_for(VpnChannelRuntime::AsyncPollInterval);
                }
                if (canceled.load()) throw hresult_canceled();
                const auto result = operation.GetResults();
                if (!result) throw hresult_canceled();
                const auto passkey = result.PasskeyCredential();
                if (!passkey) throw hresult_canceled();
                TunnelCredentials credentials{};
                credentials.username = to_string(passkey.UserName());
                credentials.password = to_string(passkey.Password());
                return credentials;
            }
        );
        if (canceled.load()) throw hresult_canceled();
        // Neither the registration nor the stored profile receives these credentials.
        const auto connection_profile = prepared.ToJson().Encode();
        loop = std::make_unique<RuntimeLoop>();
        partout_daemon_start_args args{};
        args.profile = connection_profile.c_str();
        args.options = options;
        partout_winrt_callbacks callbacks{};
        callbacks.context = loop.get();
        callbacks.connect = [](
            void *context, const char *host, partout_socket_proto proto, uint16_t port,
            const partout_socket_open_options *options
        ) noexcept {
            return ABI::ConnectOnLoop(static_cast<RuntimeLoop *>(context), host, proto, port, options);
        };
        callbacks.submit = [](void *context, void (*execute)(void *), void *task) noexcept {
            return ABI::SubmitLoop(static_cast<RuntimeLoop *>(context), execute, task);
        };
        callbacks.drain = [](void *context) noexcept {
            ABI::DrainLoop(static_cast<RuntimeLoop *>(context));
        };
        partout_daemon_bindings bindings{};
        bindings.winrt = &callbacks;
        {
            std::lock_guard lock(controller_mutex);
            controller = std::make_unique<TunnelController>(*loop, channel, controller_options);
            bindings.controller = controller.get();
            bindings.controller_functions = ControllerFunctions();
        }
        // Impl outlives the daemon; Stop() drains callbacks before destruction.
        bindings.events.ctx = this;
        bindings.events.set_connection_status = [](void *ctx, const char *status) noexcept {
            const auto parsed = Models::TryReadStringEnum<Models::ConnectionStatus>(status);
            if (!parsed) return;
            static_cast<Impl *>(ctx)->OnConnectionStatus(*parsed);
        };
        bindings.release = [](partout_daemon_bindings *owned) noexcept {
            // Runtime owns the controller and loop through daemon destruction.
            owned->controller = nullptr;
        };
        args.bindings = &bindings;
        // The C ABI consumes the bindings even if startup fails.
        if (partout_daemon_start(&args) != PartoutCompletionCodeOK) {
            throw hresult_error(E_FAIL, L"Unable to start Partout daemon");
        }
        daemon_started = true;
        Log(PartoutLogLevelDebug, L"Partout::VpnChannelRuntime: waiting for connection");
        WaitForConnection();
        Log(PartoutLogLevelInfo, L"Partout::VpnChannelRuntime: connected");
    } catch (...) {
        const auto failure = to_hresult();
        wchar_t message[128]{};
        std::swprintf(message, 128,
                      L"Partout::VpnChannelRuntime: connect failed: HRESULT=0x%08x",
                      static_cast<unsigned int>(failure.value));
        Log(PartoutLogLevelError, message);
        Stop();
        try {
            channel.SetErrorMessage(L"Unable to start Partout VPN channel");
        } catch (...) {}
        throw;
    }
}

void VpnChannelRuntime::Impl::Stop() noexcept {
    // Destroying the daemon joins its actor and drains accepted preparation,
    // detaches native receive callbacks, and releases its transports.
    if (daemon_started) {
        partout_daemon_stop();
        daemon_started = false;
    }
    if (loop) {
        std::unique_ptr<TunnelController> closing;
        {
            // Wait for current plugin callbacks and reject later ones.
            std::lock_guard lock(controller_mutex);
            closing = std::move(controller);
        }
        // Do not hold the callback gate while calling VpnChannel.Stop.
        // Destroy after all accepted commands, including transport release:
        // TUN handles and socket writers borrow the controller's TUN state.
        loop->Perform([&closing] {
            closing.reset();
        });
        loop->Drain();
        loop.reset(); // Drains remaining commands, joins, then uninitializes MTA.
    }
}

void VpnChannelRuntime::Impl::WaitForConnection() {
    std::unique_lock lock(startup_mutex);
    const bool completed = startup_changed.wait_for(lock, VpnChannelRuntime::StartupTimeout, [this] {
        return StartupCompleteLocked();
    });
    if (!completed) {
        throw hresult_error(HRESULT_FROM_WIN32(ERROR_TIMEOUT), L"Partout connection timed out");
    }
    if (startup_status == StartupStatus::failed) {
        throw hresult_error(E_FAIL, L"Partout disconnected during startup");
    }
}

// Called by the daemon, including during partout_daemon_start(). Only
// publish state here: stopping the daemon from its callback would deadlock.
void VpnChannelRuntime::Impl::OnConnectionStatus(const Models::ConnectionStatus &status) noexcept {
    using Status = Models::ConnectionStatus;
    std::scoped_lock lock(startup_mutex);
    if (StartupCompleteLocked()) return;
    switch (status.value) {
    case Status::connecting:
        startup_status = StartupStatus::connecting;
        break;
    case Status::connected:
        startup_status = StartupStatus::connected;
        break;
    case Status::disconnected:
        if (startup_status == StartupStatus::connecting) startup_status = StartupStatus::failed;
        break;
    default:
        break;
    }
    // The daemon emits an initial disconnected status before connecting.
    startup_changed.notify_all();
}

void VpnChannelRuntime::Impl::CheckChannel(VpnChannel const &value) const {
    if (!value || value != channel) throw hresult_invalid_argument();
}

bool VpnChannelRuntime::Impl::StartupCompleteLocked() const {
    return startup_status == StartupStatus::connected ||
           startup_status == StartupStatus::failed;
}

void VpnChannelRuntime::Impl::Log(partout_log_level level, std::wstring_view message) const noexcept {
    try {
        channel.LogDiagnosticMessage(hstring{message});
    } catch (...) {}
    try {
        if (init_args.logger_fn) {
            const auto text = to_string(hstring{message});
            init_args.logger_fn(init_args.logger_ctx, nullptr, level, text.c_str());
        }
    } catch (...) {}
}

} // namespace Partout
