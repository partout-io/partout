// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <windows.h>
#include "tun.h"
#include "windows/log.h"
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Storage.Streams.h>
#include <cstring>
#include <mutex>
#include <utility>

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Networking;
using namespace winrt::Windows::Networking::Vpn;

namespace Partout {

int32_t Tun::State::Write(const uint8_t *bytes, size_t length, bool send) {
    if (!bytes || !length || length > UINT32_MAX) return E_INVALIDARG;
    const auto append = [&](VpnPacketBuffer const &packet) {
        if (send)
            channel.AppendVpnSendPacketBuffer(packet);
        else
            channel.AppendVpnReceivePacketBuffer(packet);
    };
    const auto flush = [&] {
        if (send)
            channel.FlushVpnSendPacketBuffers();
        else
            channel.FlushVpnReceivePacketBuffers();
    };
    VpnPacketBuffer packet{nullptr};
    const char *stage = "get buffer";
    uint32_t capacity = 0;
    try {
        packet = send ? channel.GetVpnSendPacketBuffer() : channel.GetVpnReceivePacketBuffer();
        const auto buffer = packet.Buffer();
        capacity = buffer.Capacity();
        stage = "copy packet";
        if (length > capacity) throw hresult_invalid_argument();
        memcpy(buffer.data(), bytes, length);
        buffer.Length(static_cast<uint32_t>(length));
        stage = "append";
        append(packet);
        packet = nullptr; // Ownership returned to the channel.
        stage = "flush";
        flush();
    } catch (...) {
        const auto error = to_hresult().value;
        windows_log(
            WindowsLogError,
            "Partout::Tun: %s write failed: stage=%s, HRESULT=0x%08x, length=%zu, capacity=%u",
            send ? "link" : "TUN", stage, static_cast<unsigned int>(error), length, capacity);
        // Return an unused pool buffer even if preparing the packet failed.
        if (packet) {
            try {
                packet.Buffer().Length(0);
                append(packet);
                flush();
            } catch (...) {}
        }
        return error;
    }
    return 0;
}

Tun::Tun(State &state) : state_(state) {}

Tun::~Tun() noexcept {
    StopWrites();
    std::lock_guard lock(state_.receive_mutex);
    callback_ = nullptr;
    // An older handle may be freed after Open publishes its replacement.
    if (state_.tun == this) state_.tun = nullptr;
}

bool Tun::SetOnReceive(TunOnReceive callback) {
    std::lock_guard lock(state_.receive_mutex);
    if (callback && callback_) return false;
    callback_ = std::move(callback);
    return true;
}

void Tun::ReportError(int32_t error) {
    int32_t expected = 0;
    write_status_.compare_exchange_strong(expected, error);
    std::lock_guard lock(state_.receive_mutex);
    if (callback_) callback_(nullptr, 0, error);
}

int32_t Tun::Write(const uint8_t *bytes, size_t length) {
    if (auto status = WriteStatus()) return status;
    const auto result = state_.Write(bytes, length, false);
    if (result) {
        ++state_.counters.tun_write_failed;
        return result;
    }
    ++state_.counters.tun_write;
    return 0;
}

void Tun::StopWrites() {
    write_status_ = E_ABORT;
}

} // namespace Partout
