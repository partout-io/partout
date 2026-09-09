// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <windows.h>
#include <roapi.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.System.Threading.h>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <deque>
#include <limits>
#include <memory>
#include <mutex>
#include <vector>
#include "portable/socket_winrt.h"

using namespace winrt;
using namespace winrt::Windows::Foundation;
using namespace winrt::Windows::Networking;
using namespace winrt::Windows::Networking::Sockets;
using namespace winrt::Windows::Storage::Streams;

// Zig's looper threads do not initialize WinRT. Balance initialization once
// per thread, preserving an existing STA when called from an application.
static void ensure_apartment() {
    struct Apartment {
        HRESULT result = RoInitialize(RO_INIT_MULTITHREADED);
        Apartment() { if (result != RPC_E_CHANGED_MODE) check_hresult(result); }
        ~Apartment() { if (SUCCEEDED(result)) RoUninitialize(); }
    };
    thread_local Apartment apartment;
}

struct ReceiveQueue {
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::mutex mutex;
    std::deque<std::vector<uint8_t>> packets;
    size_t bytes = 0;
    size_t capacity = 0;
    int32_t error = 0;
    bool watch_read = false;
    bool watch_write = false;
    bool read_ready = false;
    bool write_ready = false;
    bool connect_ready = false;
    bool connecting = true;
    bool terminal = false;

    ReceiveQueue() { if (!event) throw_last_error(); }
    ~ReceiveQueue() { CloseHandle(event); }
    // All readiness updates and resets share this mutex, including UDP enqueue.
    void refresh() {
        const bool ready = ((watch_read || watch_write) && (terminal || error)) ||
            (watch_read && (connect_ready || read_ready || !packets.empty())) ||
            (watch_write && write_ready);
        if (ready) SetEvent(event); else ResetEvent(event);
    }
};

struct pp_winrt_socket {
    DatagramSocket udp{nullptr};
    StreamSocket tcp{nullptr};
    IAsyncAction connect{nullptr};
    IAsyncOperationWithProgress<IBuffer, uint32_t> read{nullptr};
    IAsyncOperationWithProgress<uint32_t, uint32_t> write{nullptr};
    std::shared_ptr<ReceiveQueue> receive = std::make_shared<ReceiveQueue>();
    std::chrono::steady_clock::time_point started;
    int timeout_ms = 0;
    int32_t error = 0;
    uint32_t write_size = 0;
    int32_t argument_error = 0;
    bool eof = false;
    uint32_t read_offset = 0;
    winrt::Windows::System::Threading::ThreadPoolTimer deadline{nullptr};

    ~pp_winrt_socket() {
        // Callback captures only a weak queue reference, never this handle.
        try { if (deadline) deadline.Cancel(); } catch (...) {}
        try { if (connect) connect.Cancel(); } catch (...) {}
        try { if (read) read.Cancel(); } catch (...) {}
        try { if (write) write.Cancel(); } catch (...) {}
        try { if (udp) udp.Close(); } catch (...) {}
        try { if (tcp) tcp.Close(); } catch (...) {}
    }
};

pp_winrt_socket_ref pp_winrt_socket_open(const char *host,
    uint16_t port, int tcp, int timeout_ms, size_t capacity, int32_t *error,
    const pp_reachability *reachability, pp_socket_configure configure, void *configure_ctx) {
    if (error) *error = 0;
    try {
        ensure_apartment();
        if (!host || !*host || (tcp != 0 && tcp != 1) || capacity == 0 ||
            capacity > INT_MAX) throw hresult_invalid_argument();
        auto socket = std::make_unique<pp_winrt_socket>();
        socket->receive->capacity = capacity;
        socket->timeout_ms = timeout_ms;
        const HostName hostname{to_hstring(host)};
        const auto service = to_hstring(std::to_string(port));
        if (tcp) {
            socket->tcp = StreamSocket{};
        } else {
            socket->udp = DatagramSocket{};
            std::weak_ptr<ReceiveQueue> weak = socket->receive;
            socket->udp.MessageReceived([weak](auto const &, auto const &args) noexcept {
                auto queue = weak.lock();
                if (!queue) return;
                try {
                    const auto reader = args.GetDataReader();
                    const auto size = reader.UnconsumedBufferLength();
                    std::scoped_lock lock(queue->mutex);
                    // UDP may drop on overflow. Bound empty datagrams as well.
                    if (size > queue->capacity - queue->bytes ||
                        queue->packets.size() >= 1024) return;
                    std::vector<uint8_t> packet(size);
                    reader.ReadBytes(packet);
                    queue->packets.push_back(std::move(packet));
                    queue->bytes += size;
                    queue->refresh();
                } catch (...) {
                    const auto code = static_cast<int32_t>(to_hresult());
                    std::scoped_lock lock(queue->mutex);
                    queue->error = code;
                    queue->refresh();
                }
            });
        }
        // Association must finish while the transport is still unconnected.
        // unique_ptr closes the transport if configuration rejects it or throws.
        if (configure && !configure(configure_ctx,
            reinterpret_cast<pp_socket_fd>(socket.get()), reachability)) {
            throw hresult_error(E_ABORT, L"Socket configuration failed");
        }
        socket->started = std::chrono::steady_clock::now();
        socket->connect = tcp ? socket->tcp.ConnectAsync(hostname, service)
                              : socket->udp.ConnectAsync(hostname, service);
        std::weak_ptr<ReceiveQueue> weak = socket->receive;
        socket->connect.Completed([weak](auto const &, AsyncStatus status) noexcept {
            if (auto state = weak.lock()) {
                std::scoped_lock lock(state->mutex);
                state->connecting = false;
                state->connect_ready = true;
                state->write_ready = status == AsyncStatus::Completed;
                state->terminal = status != AsyncStatus::Completed;
                state->refresh();
            }
        });
        if (timeout_ms > 0) {
            socket->deadline = winrt::Windows::System::Threading::ThreadPoolTimer::CreateTimer(
                [weak](auto const &) noexcept {
                    if (auto state = weak.lock()) {
                        std::scoped_lock lock(state->mutex);
                        if (state->connecting) {
                            state->error = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
                            state->refresh();
                        }
                    }
                }, std::chrono::milliseconds(timeout_ms));
        }
        return socket.release();
    } catch (...) {
        if (error) *error = static_cast<int32_t>(to_hresult());
        return nullptr;
    }
}

int pp_winrt_socket_poll(pp_winrt_socket_ref socket) {
    if (!socket) return PPWinRTFailure;
    try {
        ensure_apartment();
        if (socket->error) return PPWinRTFailure;
        {
            std::scoped_lock lock(socket->receive->mutex);
            if (socket->receive->error) {
                socket->error = socket->receive->error;
                return PPWinRTFailure;
            }
        }
        if (socket->connect) {
            bool connecting;
            {
                std::scoped_lock lock(socket->receive->mutex);
                connecting = socket->receive->connecting;
            }
            // Completion flags are published under the mutex. Do not consume
            // an operation before its callback has published readiness.
            if (connecting) {
                if (socket->timeout_ms > 0 && std::chrono::steady_clock::now() -
                    socket->started >= std::chrono::milliseconds(socket->timeout_ms)) {
                    socket->error = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
                    socket->connect.Cancel();
                    return PPWinRTFailure;
                }
                return PPWinRTWouldBlock;
            }
            socket->connect.GetResults();
            socket->connect = nullptr;
            std::scoped_lock lock(socket->receive->mutex);
            socket->receive->connect_ready = false;
            socket->receive->refresh();
        }
        bool write_ready;
        bool read_failed;
        {
            std::scoped_lock lock(socket->receive->mutex);
            write_ready = socket->receive->write_ready;
            read_failed = socket->receive->terminal && socket->receive->read_ready;
        }
        if (socket->read && read_failed) socket->read.GetResults();
        if (socket->write && write_ready) {
            if (socket->write.GetResults() != socket->write_size)
                throw hresult_error(E_FAIL, L"Incomplete asynchronous write");
            socket->write = nullptr;
        }
        return 0;
    } catch (...) {
        socket->error = static_cast<int32_t>(to_hresult());
        return PPWinRTFailure;
    }
}

static void start_read(pp_winrt_socket_ref socket) {
    if (!socket->tcp || socket->read || socket->eof) return;
    {
        std::scoped_lock lock(socket->receive->mutex);
        socket->receive->read_ready = false;
        socket->receive->refresh();
    }
    const auto count = static_cast<uint32_t>(socket->receive->capacity);
    socket->read = socket->tcp.InputStream().ReadAsync(
        Buffer(count), count, InputStreamOptions::Partial);
    std::weak_ptr<ReceiveQueue> weak = socket->receive;
    socket->read.Completed([weak](auto const &, AsyncStatus status) noexcept {
        if (auto state = weak.lock()) {
            std::scoped_lock lock(state->mutex);
            state->read_ready = true;
            state->terminal = state->terminal || status != AsyncStatus::Completed;
            state->refresh();
        }
    });
}

int pp_winrt_socket_read(pp_winrt_socket_ref socket, uint8_t *dst, size_t size) {
    const int status = pp_winrt_socket_poll(socket);
    if (status != 0) return status;
    try {
        ensure_apartment();
        if (!dst || size == 0) throw hresult_invalid_argument();
        if (socket->udp) {
            auto &queue = *socket->receive;
            std::scoped_lock lock(queue.mutex);
            if (queue.packets.empty()) return PPWinRTWouldBlock;
            const auto &packet = queue.packets.front();
            if (size < packet.size()) {
                socket->argument_error = HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
                return PPWinRTFailure;
            }
            const auto count = packet.size();
            if (count) std::memcpy(dst, packet.data(), count);
            queue.bytes -= count;
            queue.packets.pop_front();
            queue.refresh();
            return static_cast<int>(count);
        }
        if (socket->eof) return 0;
        start_read(socket);
        {
            std::scoped_lock lock(socket->receive->mutex);
            if (!socket->receive->read_ready) return PPWinRTWouldBlock;
        }
        auto buffer = socket->read.GetResults();
        const auto count = static_cast<uint32_t>(std::min(size,
            static_cast<size_t>(buffer.Length() - socket->read_offset)));
        if (count) std::memcpy(dst, buffer.data() + socket->read_offset, count);
        socket->read_offset += count;
        if (socket->read_offset == buffer.Length()) {
            socket->read_offset = 0;
            socket->read = nullptr;
            socket->eof = count == 0;
            if (!socket->eof) start_read(socket);
        }
        return static_cast<int>(count);
    } catch (...) {
        socket->error = static_cast<int32_t>(to_hresult());
        return PPWinRTFailure;
    }
}

int pp_winrt_socket_write(pp_winrt_socket_ref socket, const uint8_t *src, size_t size) {
    const int status = pp_winrt_socket_poll(socket);
    if (status != 0) return status;
    try {
        ensure_apartment();
        if ((!src && size) || size > socket->receive->capacity || size > INT_MAX)
            throw hresult_invalid_argument();
        if (socket->write) return PPWinRTWouldBlock;
        Buffer buffer(static_cast<uint32_t>(size));
        buffer.Length(static_cast<uint32_t>(size));
        if (size) std::memcpy(buffer.data(), src, size);
        socket->write_size = static_cast<uint32_t>(size);
        const auto stream = socket->tcp ? socket->tcp.OutputStream() : socket->udp.OutputStream();
        {
            std::scoped_lock lock(socket->receive->mutex);
            socket->receive->write_ready = false;
            socket->receive->refresh();
        }
        socket->write = stream.WriteAsync(buffer);
        std::weak_ptr<ReceiveQueue> weak = socket->receive;
        socket->write.Completed([weak, expected = socket->write_size](auto const &operation, AsyncStatus status) noexcept {
            if (auto state = weak.lock()) {
                int32_t error = 0;
                try {
                    if (operation.GetResults() != expected) error = E_FAIL;
                } catch (...) { error = static_cast<int32_t>(to_hresult()); }
                std::scoped_lock lock(state->mutex);
                state->write_ready = true;
                state->terminal = state->terminal || status != AsyncStatus::Completed;
                if (error) state->error = error;
                state->refresh();
            }
        });
        return static_cast<int>(size);
    } catch (...) {
        socket->error = static_cast<int32_t>(to_hresult());
        return PPWinRTFailure;
    }
}

int32_t pp_winrt_socket_error(pp_winrt_socket_ref socket) {
    return socket ? (socket->error ? socket->error : socket->argument_error) : E_INVALIDARG;
}

void *pp_winrt_socket_watch_handle(pp_winrt_socket_ref socket) {
    return socket ? socket->receive->event : nullptr;
}

int pp_winrt_socket_set_event_mask(pp_winrt_socket_ref socket, int read, int write) {
    if (!socket) return PPWinRTFailure;
    try {
        ensure_apartment();
        {
            std::scoped_lock lock(socket->receive->mutex);
            socket->receive->watch_read = read != 0;
            socket->receive->watch_write = write != 0;
            socket->receive->refresh();
        }
        const auto status = pp_winrt_socket_poll(socket);
        if (status == PPWinRTFailure) return status;
        if (read && status == 0) start_read(socket);
        return 0;
    } catch (...) {
        socket->error = static_cast<int32_t>(to_hresult());
        return PPWinRTFailure;
    }
}

int pp_winrt_socket_reset_events(pp_winrt_socket_ref socket) {
    if (!socket) return PPWinRTFailure;
    std::scoped_lock lock(socket->receive->mutex);
    socket->receive->refresh();
    return 0;
}

void pp_winrt_socket_close(pp_winrt_socket_ref socket) { delete socket; }

void *pp_winrt_socket_get_transport(const struct pp_winrt_socket *socket) {
    if (!socket) return nullptr;
    if (socket->udp) return winrt::get_abi(socket->udp);
    if (socket->tcp) return winrt::get_abi(socket->tcp);
    return nullptr;
}
