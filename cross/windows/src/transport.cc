// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <winsock2.h>
#include "transport.h"
#include <vector>
#include <optional>
#include <winrt/Windows.Networking.h>
#include <winrt/Windows.Networking.Sockets.h>

namespace Partout {
Transport::Transport(RuntimeLoop &loop, std::unique_ptr<Socket> value)
    : socket(std::move(value)), loop_(loop) {}

Transport::Transport(RuntimeLoop &loop, std::unique_ptr<Tun> value)
    : tun(std::move(value)), loop_(loop) {}

int32_t Transport::WriteStatus() const {
    return socket ? socket->WriteStatus() : tun->WriteStatus();
}

void Transport::ReportError(int32_t error) {
    if (socket)
        socket->ReportError(error);
    else
        tun->ReportError(error);
}

bool Transport::ResumeReading() {
    try {
        loop_.Post([this] {
            if (socket && !socket->ResumeReading())
                ReportError(E_FAIL);
        });
        return true;
    } catch (...) {
        return false;
    }
}

bool Transport::GetAddress(SocketAddress *address) {
    return loop_.Invoke([this, address] {
        return socket && socket->GetAddress(address);
    });
}

void Transport::StopWrites() {
    if (socket)
        socket->StopWrites();
    else
        tun->StopWrites();
}

int32_t Transport::Write(const uint8_t *bytes, size_t size, const SocketAddress *destination) {
    if (auto status = WriteStatus())
        return status;
    if ((!bytes && size) || size > UINT32_MAX || (IsUnconnected() && !destination))
        return E_INVALIDARG;
    if (socket && !socket->Accepts(destination))
        return E_INVALIDARG;
    try {
        std::vector<uint8_t> copy;
        if (size)
            copy.assign(bytes, bytes + size);
        std::optional<SocketAddress> address;
        if (destination)
            address = *destination;
        loop_.Post([this, copy = std::move(copy), address] {
            if (WriteStatus())
                return;
            auto result =
                socket ? socket->Write(copy.data(), copy.size(), address ? &*address : nullptr)
                       : tun->Write(copy.data(), copy.size());
            if (result)
                ReportError(result);
        });
        return 0;
    } catch (...) {
        return winrt::to_hresult().value;
    }
}

} // namespace Partout
