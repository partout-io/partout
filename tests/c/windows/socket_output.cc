// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <winsock2.h>
#include "../../../cross/windows/src/socket.h"
#include "../../../cross/windows/src/loop.h"
#include "../../../cross/windows/include/windows/abi.h"
#include "../../../cross/windows/include/windows/log.h"
#include <cassert>
#include <chrono>
#include <cstdio>
#include <future>
#include <thread>
#include <mutex>
#include <string>
#include <vector>

std::mutex logMutex;
std::vector<std::string> messages;
void CaptureLog(windows_log_level, const char *message) {
    std::lock_guard lock(logMutex);
    messages.emplace_back(message);
}

void TestBorrowedChannelOutput() {
    Partout::Socket socket(Partout::SocketProtoUDP, false);
    const uint8_t bytes[]{1, 2, 3, 4};
    std::thread::id producer;
    size_t calls = 0;
    auto receiver = socket.TakeOver([&](const uint8_t *input, size_t size) {
        assert(std::this_thread::get_id() == producer);
        assert(input == bytes && size == sizeof(bytes));
        ++calls;
        return int32_t{0};
    });
    // Like the Go output producer, this thread has no explicit COM apartment.
    std::thread writer([&] {
        producer = std::this_thread::get_id();
        assert(socket.Write(bytes, sizeof(bytes), nullptr) == 0);
    });
    writer.join();
    assert(calls == 1);
    socket.StopWrites();
    assert(socket.Write(bytes, sizeof(bytes), nullptr) == E_ABORT);
    assert(calls == 1);
}

void TestChannelFailureLatches() {
    Partout::Socket socket(Partout::SocketProtoUDP, false);
    size_t calls = 0;
    auto receiver = socket.TakeOver([&](const uint8_t *, size_t) {
        ++calls;
        return int32_t{E_FAIL};
    });
    const uint8_t bytes[]{1};
    assert(socket.Write(bytes, sizeof(bytes), nullptr) == E_FAIL);
    assert(socket.Write(bytes, sizeof(bytes), nullptr) == E_FAIL);
    assert(calls == 1);
    socket.StopWrites();
    assert(socket.Write(bytes, sizeof(bytes), nullptr) == E_ABORT);
}

void TestOutputBypassesWorker() {
    Partout::RuntimeLoop loop;
    const auto peer = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    assert(peer != INVALID_SOCKET);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(peer, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0);
    int address_size = sizeof(address);
    assert(getsockname(peer, reinterpret_cast<sockaddr *>(&address), &address_size) == 0);
    const DWORD timeout = 1000;
    assert(setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO,
                     reinterpret_cast<const char *>(&timeout), sizeof(timeout)) == 0);
    windows_connect_options options{};
    options.timeout_ms = 1000;
    auto transport = windows_connect("127.0.0.1", ntohs(address.sin_port), &options);
    assert(transport);

    std::promise<void> entered, release;
    auto released = release.get_future();
    loop.Schedule([&] {
        entered.set_value();
        // A broken implementation must fail the receive timeout, not hang forever.
        released.wait_for(std::chrono::seconds(5));
    });
    entered.get_future().get();
    uint8_t bytes[]{1, 2, 3, 4};
    assert(transport->write(transport->context, bytes, sizeof(bytes), nullptr) == 0);
    bytes[0] = 9; // The asynchronous socket must own its payload after return.
    char received[4]{};
    assert(recv(peer, received, sizeof(received), 0) == sizeof(received));
    assert(received[0] == 1 && received[3] == 4);
    release.set_value();
    transport->release(transport->context);
    loop.Drain();
    closesocket(peer);
}

void TestReplyDuringReceive() {
    const auto peer = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    assert(peer != INVALID_SOCKET);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(peer, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0);
    int size = sizeof(address);
    assert(getsockname(peer, reinterpret_cast<sockaddr *>(&address), &size) == 0);
    const DWORD timeout = 1000;
    assert(setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO,
                     reinterpret_cast<const char *>(&timeout), sizeof(timeout)) == 0);
    Partout::Socket socket(Partout::SocketProtoUDP, false);
    const Partout::SocketOpenOptions options{false, 1000};
    assert(socket.Open("127.0.0.1", ntohs(address.sin_port), &options));
    Partout::SocketAddress local{};
    assert(socket.GetAddress(&local));
    address.sin_port = htons(local.port);
    assert(socket.SetOnReceive([&](const uint8_t *bytes, size_t length,
                                  const Partout::SocketAddress *, int32_t error) {
        assert(error == 0);
        // OpenVPN negotiation replies now run inside native receive delivery.
        assert(socket.Write(bytes, length, nullptr) == 0);
        return true;
    }));
    assert(sendto(peer, "reply", 5, 0, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 5);
    char received[5]{};
    assert(recv(peer, received, sizeof(received), 0) == sizeof(received));
    assert(received[0] == 'r' && received[4] == 'y');
    assert(socket.SetOnReceive({}));
    closesocket(peer);
}

void TestBatchDestinationsAndStreamCache() {
    Partout::RuntimeLoop loop;
    SOCKET peers[2];
    windows_address destinations[2]{};
    for (size_t i = 0; i < 2; ++i) {
        peers[i] = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        assert(peers[i] != INVALID_SOCKET);
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(bind(peers[i], reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0);
        int size = sizeof(address);
        assert(getsockname(peers[i], reinterpret_cast<sockaddr *>(&address), &size) == 0);
        const DWORD timeout = 1000;
        assert(setsockopt(peers[i], SOL_SOCKET, SO_RCVTIMEO,
                         reinterpret_cast<const char *>(&timeout), sizeof(timeout)) == 0);
        destinations[i].family = 4;
        destinations[i].address[0] = 127;
        destinations[i].address[3] = 1;
        destinations[i].port = ntohs(address.sin_port);
    }
    windows_connect_options options{};
    options.unconnected = true;
    options.timeout_ms = 1000;
    auto transport = windows_connect("127.0.0.1", 0, &options);
    assert(transport && transport->write_batch);
    windows_set_logger(CaptureLog);
    for (size_t round = 0; round < 2; ++round) {
        for (size_t peer = 0; peer < 2; ++peer) {
            uint8_t payload[3]{static_cast<uint8_t>(peer), static_cast<uint8_t>(round), 42};
            windows_packet packets[3]{{payload, 1}, {payload, 2}, {payload, 3}};
            size_t written = 0;
            assert(transport->write_batch(transport->context, packets, 3, &destinations[peer], &written) == 0);
            assert(written == 3);
            payload[0] = 99; // Asynchronous writes must own the bytes.
            for (size_t packet = 0; packet < 3; ++packet) {
                char received[8]{};
                assert(recv(peers[peer], received, sizeof(received), 0) == packet + 1);
                assert(received[0] == peer);
                if (packet > 0) assert(received[1] == round);
            }
        }
    }
    transport->release(transport->context);
    loop.Drain();
    windows_set_logger(nullptr);
    bool found = false;
    for (const auto &message : messages) {
        if (message.find("hits=10 misses=2 entries=2") != std::string::npos) found = true;
    }
    assert(found);
    for (auto peer : peers) closesocket(peer);
}

int main() {
    WSADATA data{};
    assert(WSAStartup(MAKEWORD(2, 2), &data) == 0);
    TestBorrowedChannelOutput();
    TestChannelFailureLatches();
    TestOutputBypassesWorker();
    TestReplyDuringReceive();
    TestBatchDestinationsAndStreamCache();
    WSACleanup();
    std::puts("Direct Windows output tests passed");
}
