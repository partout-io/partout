// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <partout/Runtime.h>
#include <cassert>
#include <stdexcept>
#include <string>

int main() {
    Partout::Runtime::Initialize({});
    assert(!Partout::Runtime::WireGuardPublicKey("invalid-key"));
    bool rejected = false;
    try {
        Partout::Runtime::ImportProfile("invalid configuration containing PRIVATE_SECRET");
    } catch (const std::runtime_error &error) {
        rejected = true;
        assert(std::string(error.what()) == "Partout could not import this configuration.");
    }
    assert(rejected);
}
