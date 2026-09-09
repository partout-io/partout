// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <winsock2.h>
#include <winrt/base.h>
#include <winrt/Windows.Networking.Sockets.h>
#include "portable/socket_winrt.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

static void require(bool value) { if (!value) std::abort(); }

struct Configuration {
    bool tcp;
    bool accept;
    int calls = 0;
    const pp_reachability *reachability;
};

static bool configure_socket(void *ctx, pp_socket_fd fd, const pp_reachability *reachability) {
    auto &configuration = *static_cast<Configuration *>(ctx);
    ++configuration.calls;
    require(reachability == configuration.reachability);
    auto socket = reinterpret_cast<pp_winrt_socket_ref>(fd);
    const auto raw = pp_winrt_socket_get_transport(socket);
    require(raw != nullptr);
    winrt::Windows::Foundation::IInspectable transport{nullptr};
    winrt::copy_from_abi(transport, raw);
    using namespace winrt::Windows::Networking::Sockets;
    // The transport exists, but neither TCP nor UDP has a remote endpoint yet.
    if (configuration.tcp) require(transport.as<StreamSocket>().Information().RemotePort().empty());
    else require(transport.as<DatagramSocket>().Information().RemotePort().empty());
    return configuration.accept;
}
template<class F> static int wait(F operation) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    int result;
    do {
        result = operation();
        if (result != PPWinRTWouldBlock) return result;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    } while (std::chrono::steady_clock::now() < deadline);
    std::abort();
}

template<class F> static int wait_event(pp_winrt_socket_ref socket, F operation) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    for (;;) {
        const int result = operation();
        if (result != PPWinRTWouldBlock) return result;
        require(std::chrono::steady_clock::now() < deadline);
        require(WaitForSingleObject(pp_winrt_socket_watch_handle(socket), 5000) == WAIT_OBJECT_0);
        require(pp_winrt_socket_reset_events(socket) == 0);
    }
}

static void roundtrip(bool tcp) {
    const SOCKET server = socket(AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, 0);
    require(server != INVALID_SOCKET);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    require(bind(server, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0);
    int length = sizeof(address);
    require(getsockname(server, reinterpret_cast<sockaddr *>(&address), &length) == 0);
    if (tcp) require(listen(server, 1) == 0);
    std::thread echo([=] {
        char bytes[32];
        if (tcp) {
            const auto peer = accept(server, nullptr, nullptr);
            require(peer != INVALID_SOCKET);
            // Collect the request independent of TCP fragmentation.
            int count = 0;
            while (count < 4) {
                const int n = recv(peer, bytes + count, 4 - count, 0);
                require(n > 0);
                count += n;
            }
            require(send(peer, bytes, count, 0) == count);
            shutdown(peer, SD_SEND);
            closesocket(peer);
        } else {
            sockaddr_in peer{};
            int size = sizeof(peer);
            const int count = recvfrom(server, bytes, sizeof(bytes), 0,
                reinterpret_cast<sockaddr *>(&peer), &size);
            require(count == 4);
            require(sendto(server, bytes, count, 0,
                reinterpret_cast<sockaddr *>(&peer), size) == count);
        }
    });
    int32_t error = 0;
    const pp_reachability reachability{true};
    Configuration configuration{tcp, true, 0, &reachability};
    auto client = pp_winrt_socket_open("127.0.0.1", ntohs(address.sin_port), tcp, 3000, 1024, &error,
        &reachability, configure_socket, &configuration);
    require(client && error == 0);
    require(configuration.calls == 1);
    require(pp_winrt_socket_set_event_mask(client, 0, 1) == 0);
    require(wait_event(client, [&] { return pp_winrt_socket_poll(client); }) == 0);
    uint8_t received[32]{};
    require(pp_winrt_socket_read(client, received, sizeof(received)) == PPWinRTWouldBlock);
    uint8_t sent[] = {1, 2, 3, 4};
    require(wait_event(client, [&] { return pp_winrt_socket_write(client, sent, sizeof(sent)); }) == 4);
    std::memset(sent, 0, sizeof(sent)); // Async writer must own its copy.
    require(pp_winrt_socket_set_event_mask(client, 0, 0) == 0);
    require(WaitForSingleObject(pp_winrt_socket_watch_handle(client), 0) == WAIT_TIMEOUT);
    require(pp_winrt_socket_set_event_mask(client, 1, 0) == 0);
    if (!tcp) {
        require(wait_event(client, [&] { return pp_winrt_socket_read(client, received, 1); }) == PPWinRTFailure);
        require(pp_winrt_socket_error(client) != 0);
        // A short destination must not discard the pending datagram.
    }
    int count = 0;
    while (count < 4) {
        const int n = wait_event(client, [&] { return pp_winrt_socket_read(client, received + count,
            tcp ? 1 : sizeof(received) - count); });
        require(n > 0);
        count += n;
    }
    require(count == 4 && received[0] == 1 && received[3] == 4);
    if (tcp) require(wait_event(client, [&] { return pp_winrt_socket_read(client, received, sizeof(received)); }) == 0);
    else {
        require(pp_winrt_socket_reset_events(client) == 0);
        require(WaitForSingleObject(pp_winrt_socket_watch_handle(client), 0) == WAIT_TIMEOUT);
    }
    pp_winrt_socket_close(client);
    echo.join();
    closesocket(server);
}

int main() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    WSADATA data;
    require(WSAStartup(MAKEWORD(2, 2), &data) == 0);
    int32_t error = 0;
    require(!pp_winrt_socket_open(nullptr, 0, 0, 0, 1024, &error, nullptr, nullptr, nullptr) && error != 0);
    for (bool tcp : {false, true}) {
        Configuration rejected{tcp, false, 0, nullptr};
        require(!pp_winrt_socket_open("127.0.0.1", 9, tcp, 3000, 1024, &error,
            nullptr, configure_socket, &rejected));
        require(rejected.calls == 1 && error != 0);
    }
    roundtrip(false);
    std::thread worker([] { roundtrip(true); }); // No caller-side WinRT initialization.
    worker.join();
    // A refused connection must wake a reader even without write interest.
    const SOCKET reserved = socket(AF_INET, SOCK_STREAM, 0);
    require(reserved != INVALID_SOCKET);
    sockaddr_in refused{};
    refused.sin_family = AF_INET;
    refused.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    require(bind(reserved, reinterpret_cast<sockaddr *>(&refused), sizeof(refused)) == 0);
    int refused_size = sizeof(refused);
    require(getsockname(reserved, reinterpret_cast<sockaddr *>(&refused), &refused_size) == 0);
    // A bound socket that isn't listening rejects TCP connections.
    auto failed = pp_winrt_socket_open("127.0.0.1", ntohs(refused.sin_port), 1, 3000, 1024, &error,
        nullptr, nullptr, nullptr);
    require(failed != nullptr);
    const auto armed = pp_winrt_socket_set_event_mask(failed, 1, 0);
    require(armed == PPWinRTFailure ||
        wait_event(failed, [&] { return pp_winrt_socket_poll(failed); }) == PPWinRTFailure);
    require(pp_winrt_socket_error(failed) != 0);
    pp_winrt_socket_close(failed);
    closesocket(reserved);
    // Closing a pending connect must not leave callbacks using freed state.
    auto pending = pp_winrt_socket_open("127.0.0.1", 9, 1, 3000, 1024, &error, nullptr, nullptr, nullptr);
    require(pending != nullptr);
    pp_winrt_socket_close(pending);
    WSACleanup();
    std::puts("WinRT socket tests passed (event-driven UDP/TCP, masks, EOF, copied writes, refusal, pending close)");
}
