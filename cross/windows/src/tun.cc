// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <windows.h>
#include "tun.h"
#include "io_metrics.h"
#include "loop.h"
#include "socket.h"
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

void Tun::State::AppendSend(VpnPacketBuffer const &packet) {
    ScopedIOTiming timing(append_time[1]);
    channel.AppendVpnSendPacketBuffer(packet);
}

void Tun::State::FlushSend() {
    ScopedIOTiming timing(flush_time[1]);
    channel.FlushVpnSendPacketBuffers();
}

int32_t Tun::State::SendBatch(const PacketView *packets, size_t count, size_t *written) {
    *written = 0;
    std::lock_guard lock(write_mutex);
    if (!accepting_writes) return E_ABORT;
    if (!packets || !count || count > MaxPacketBatch) return E_INVALIDARG;
    for (size_t i = 0; i < count; ++i) {
        if (!packets[i].data || !packets[i].size || packets[i].size > UINT32_MAX) return E_INVALIDARG;
    }
    size_t length = 0;
    VpnPacketBuffer packet{nullptr};
    const char *stage = "get buffer";
    uint32_t capacity = 0;
    try {
        for (size_t i = 0; i < count; ++i) {
            length = packets[i].size;
            stage = "get buffer";
            {
                ScopedIOTiming timing(get_buffer_time[1]);
                packet = channel.GetVpnSendPacketBuffer();
            }
            const auto buffer = packet.Buffer();
            capacity = buffer.Capacity();
            stage = "copy packet";
            if (length > capacity) throw hresult_invalid_argument();
            {
                ScopedIOTiming timing(copy_time[1]);
                memcpy(buffer.data(), packets[i].data, length);
                buffer.Length(static_cast<uint32_t>(length));
            }
            stage = "append";
            AppendSend(packet);
            packet = nullptr; // Ownership returned to the channel.
            ++*written;
        }
        stage = "flush";
        FlushSend();
    } catch (...) {
        const auto error = to_hresult().value;
        windows_log(
            WindowsLogError,
            "Partout::Tun: %s write failed: stage=%s, HRESULT=0x%08x, length=%zu, capacity=%u",
            "link", stage, static_cast<unsigned int>(error), length, capacity);
        // Return an unused pool buffer even if preparing the packet failed.
        if (packet) {
            try {
                packet.Buffer().Length(0);
                AppendSend(packet);
            } catch (...) {}
        }
        if (*written || packet) {
            try {
                FlushSend();
            } catch (...) {}
        }
        ++counters.link_send_failed;
        return error;
    }
    counters.link_send += *written;
    return 0;
}

void Tun::State::AppendReceive(VpnPacketBuffer const &packet) {
    ScopedIOTiming timing(append_time[0]);
    channel.AppendVpnReceivePacketBuffer(packet);
}

void Tun::State::FlushReceive() {
    ScopedIOTiming timing(flush_time[0]);
    channel.FlushVpnReceivePacketBuffers();
}

int32_t Tun::State::ReceiveBatch(const PacketView *packets, size_t count, size_t *written) {
    *written = 0;
    std::lock_guard lock(write_mutex);
    if (!accepting_writes) return E_ABORT;
    if (!packets || !count || count > MaxPacketBatch) return E_INVALIDARG;
    for (size_t i = 0; i < count; ++i) {
        if (!packets[i].data || !packets[i].size || packets[i].size > UINT32_MAX) return E_INVALIDARG;
    }
    size_t length = 0;
    VpnPacketBuffer packet{nullptr};
    const char *stage = "get buffer";
    uint32_t capacity = 0;
    try {
        for (size_t i = 0; i < count; ++i) {
            length = packets[i].size;
            stage = "get buffer";
            {
                ScopedIOTiming timing(get_buffer_time[0]);
                packet = channel.GetVpnReceivePacketBuffer();
            }
            const auto buffer = packet.Buffer();
            capacity = buffer.Capacity();
            stage = "copy packet";
            if (length > capacity) throw hresult_invalid_argument();
            {
                ScopedIOTiming timing(copy_time[0]);
                memcpy(buffer.data(), packets[i].data, length);
                buffer.Length(static_cast<uint32_t>(length));
            }
            stage = "append";
            AppendReceive(packet);
            packet = nullptr; // Ownership returned to the channel.
            ++*written;
        }
        stage = "flush";
        FlushReceive();
    } catch (...) {
        const auto error = to_hresult().value;
        windows_log(
            WindowsLogError,
            "Partout::Tun: %s write failed: stage=%s, HRESULT=0x%08x, length=%zu, capacity=%u",
            "TUN", stage, static_cast<unsigned int>(error), length, capacity);
        // Return an unused pool buffer even if preparing the packet failed.
        if (packet) {
            try {
                packet.Buffer().Length(0);
                AppendReceive(packet);
            } catch (...) {}
        }
        if (*written || packet) {
            try {
                FlushReceive();
            } catch (...) {}
        }
        ++counters.tun_write_failed;
        return error;
    }
    counters.tun_write += *written;
    return 0;
}

Tun::Tun(State &state) : state_(state) {}

Tun::~Tun() noexcept {
    StopWrites();
    std::lock_guard lock(state_.receive_mutex);
    callback_ = nullptr;
    batch_callback_ = nullptr;
    // An older handle may be freed after Open publishes its replacement.
    if (state_.tun == this) state_.tun = nullptr;
}

bool Tun::SetOnReceive(TunOnReceive callback) {
    std::lock_guard lock(state_.receive_mutex);
    if (callback && (callback_ || batch_callback_)) return false;
    if (!callback) batch_callback_ = nullptr;
    callback_ = std::move(callback);
    return true;
}

bool Tun::SetOnReceiveBatch(TunOnReceiveBatch callback) {
    std::lock_guard lock(state_.receive_mutex);
    if (callback && (callback_ || batch_callback_)) return false;
    if (!callback) callback_ = nullptr;
    batch_callback_ = std::move(callback);
    return true;
}

void Tun::ReportError(int32_t error) {
    int32_t expected = 0;
    write_status_.compare_exchange_strong(expected, error);
    std::lock_guard lock(state_.receive_mutex);
    if (callback_) callback_(nullptr, 0, error);
    if (batch_callback_) batch_callback_(nullptr, 0, error);
}

int32_t Tun::Write(const uint8_t *bytes, size_t length) {
    const PacketView packet{bytes, length};
    size_t written = 0;
    return WriteBatch(&packet, 1, &written);
}

int32_t Tun::WriteBatch(const PacketView *packets, size_t count, size_t *written) {
    *written = 0;
    if (auto status = WriteStatus()) return status;
    const auto result = state_.ReceiveBatch(packets, count, written);
    if (result) {
        int32_t expected = 0;
        write_status_.compare_exchange_strong(expected, result);
    }
    return result;
}

void Tun::StopWrites() {
    write_status_ = E_ABORT;
}

} // namespace Partout
