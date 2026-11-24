// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "backend/ABI.h"
#include "backend/RuntimeLoop.h"
#include <cassert>
#include <memory>
#include <stdexcept>

namespace {

void MarkDone(void *context) {
    *static_cast<bool *>(context) = true;
}

} // namespace

int main() {
    assert(Partout::RuntimeLoop::Current() == nullptr);
    const partout_socket_open_options options{};
    assert(Partout::ABI::ConnectOnLoop(nullptr, "127.0.0.1", PartoutSocketProtoUDP, 9, &options) == nullptr);
    for (int attempt = 0; attempt < 3; ++attempt) {
        bool done = false;
        auto loop = std::make_unique<Partout::RuntimeLoop>();
        bool duplicate_rejected = false;
        try {
            Partout::RuntimeLoop duplicate;
        } catch (const std::runtime_error &) {
            duplicate_rejected = true;
        }
        assert(duplicate_rejected);
        assert(Partout::RuntimeLoop::Current() == loop.get());
        assert(Partout::ABI::SubmitLoop(loop.get(), MarkDone, &done));
        Partout::ABI::DrainLoop(loop.get());
        assert(done);
        done = false;
        assert(Partout::ABI::SubmitLoop(loop.get(), MarkDone, &done));
        loop.reset();
        assert(done);
        assert(Partout::RuntimeLoop::Current() == nullptr);
    }
}
