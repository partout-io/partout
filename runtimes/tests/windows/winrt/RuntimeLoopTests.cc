// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "backend/ABI.h"
#include <cassert>

namespace {

void MarkDone(void *context) {
    *static_cast<bool *>(context) = true;
}

} // namespace

int main() {
    assert(Partout::ABI::CurrentLoop() == nullptr);
    const partout_socket_open_options options{};
    assert(Partout::ABI::ConnectOnLoop(nullptr, "127.0.0.1", PartoutSocketProtoUDP, 9, &options) == nullptr);
    for (int attempt = 0; attempt < 3; ++attempt) {
        auto loop = Partout::ABI::CreateLoop();
        assert(loop);
        assert(Partout::ABI::CreateLoop() == nullptr);
        assert(Partout::ABI::CurrentLoop() == loop);
        bool done = false;
        assert(Partout::ABI::SubmitLoop(loop, MarkDone, &done));
        Partout::ABI::DrainLoop(loop);
        assert(done);
        done = false;
        assert(Partout::ABI::SubmitLoop(loop, MarkDone, &done));
        Partout::ABI::FreeLoop(loop);
        assert(done);
        assert(Partout::ABI::CurrentLoop() == nullptr);
    }
}
