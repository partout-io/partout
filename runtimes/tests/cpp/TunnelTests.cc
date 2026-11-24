// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <partout/tunnel/Tunnel.h>
#include <cassert>
#include <algorithm>
#include <functional>

namespace {
class Backend final : public Partout::TunnelStrategy {
public:
    std::vector<Partout::Models::TunnelSnapshot> snapshots;
    std::map<std::string, std::string> errors;
    std::optional<Partout::TunnelCredentials> credentials;
    std::vector<std::string> connections;
    unsigned saves = 0;
    bool canceled = false;

    std::vector<Partout::Models::TunnelSnapshot> Fetch() override {
        return snapshots;
    }

    std::map<std::string, std::string> ObservationErrors() const override {
        return errors;
    }

    void Save(const Partout::Models::TaggedProfile &profile) override {
        ++saves;
        Partout::Models::TunnelSnapshot snapshot{};
        snapshot.id = profile.id;
        snapshot.status.value = Partout::Models::TunnelStatus::inactive;
        const auto existing = std::find_if(snapshots.begin(), snapshots.end(), [&](const auto &item) {
            return item.id == profile.id;
        });
        if (existing == snapshots.end()) {
            snapshots.push_back(snapshot);
            return;
        }
        *existing = snapshot;
    }

    void Connect(const std::string &id) override {
        connections.push_back(id);
        SetStatus(id, Partout::Models::TunnelStatus::activating);
    }

    void ConnectWithCredentials(const std::string &id, const Partout::TunnelCredentials &value) override {
        credentials = value;
        Connect(id);
    }

    void Disconnect(const std::string &id) override {
        SetStatus(id, Partout::Models::TunnelStatus::deactivating);
    }

    void Remove(const std::string &id) override {
        snapshots.erase(std::remove_if(snapshots.begin(), snapshots.end(), [&](const auto &snapshot) {
            return snapshot.id == id;
        }), snapshots.end());
    }

    void Cancel() noexcept override {
        canceled = true;
    }

    void SetStatus(const std::string &id, Partout::Models::TunnelStatus::eTunnelStatus status) {
        for (auto &snapshot : snapshots) {
            if (snapshot.id != id) continue;
            snapshot.status.value = status;
            snapshot.isEnabled = status != Partout::Models::TunnelStatus::inactive;
            return;
        }
        throw std::runtime_error("Missing test registration");
    }
};

Partout::Models::TaggedProfile Profile(const std::string &id) {
    Partout::Models::TaggedProfile profile{};
    profile.id = id;
    return profile;
}

void Throws(const std::function<void()> &operation) {
    bool threw = false;
    try {
        operation();
    } catch (const std::runtime_error &) {
        threw = true;
    }
    assert(threw);
}
}

using namespace Partout;

int main() {
    auto backend = std::make_unique<Backend>();
    auto *native = backend.get();
    Tunnel tunnel(std::move(backend));
    const auto first = Profile("first");
    const auto second = Profile("second");
    tunnel.Save(first);
    tunnel.Save(second);
    tunnel.Save(first);
    assert(native->snapshots.size() == 2);
    native->SetStatus(first.id, Models::TunnelStatus::active);
    Throws([&] {
        tunnel.Save(first);
    });

    // Handover waits for observed disconnection and never persists login data.
    TunnelCredentials credentials{};
    credentials.username = "user";
    credentials.password = "one-time";
    tunnel.Connect(second, credentials);
    Throws([&] {
        tunnel.Save(first);
    });
    assert(native->connections.empty());
    tunnel.Advance();
    assert(native->connections.empty());
    native->SetStatus(first.id, Models::TunnelStatus::inactive);
    tunnel.Advance();
    assert(native->connections == std::vector<std::string>{second.id});
    assert(native->credentials->password == "one-time");
    assert(native->saves == 3);
    Throws([&] {
        tunnel.Save(first);
    });
    native->SetStatus(second.id, Models::TunnelStatus::active);
    tunnel.Advance();
    tunnel.Save(first);

    // An unobservable registration must not be treated as an absent one.
    native->errors[first.id] = "Unavailable";
    Throws([&] {
        tunnel.Save(first);
    });
    Throws([&] {
        tunnel.Connect(first);
    });
    Throws([&] {
        tunnel.Remove(first.id);
    });
    native->errors.clear();

    // A newer request supersedes the pending handover, including credentials.
    tunnel.Connect(first, credentials);
    tunnel.Connect(second);
    native->SetStatus(second.id, Models::TunnelStatus::inactive);
    native->credentials.reset();
    tunnel.Advance();
    assert(native->connections.back() == second.id);
    assert(!native->credentials);
    native->SetStatus(second.id, Models::TunnelStatus::inactive);
    Throws([&] {
        tunnel.Advance();
    });
    tunnel.Save(first);

    // Cancellation ends management without asking the backend to disconnect.
    tunnel.Connect(first);
    tunnel.Cancel();
    assert(native->canceled);
    Throws([&] {
        tunnel.Advance();
    });
    Throws([&] {
        tunnel.Save(first);
    });
    Throws([&] {
        tunnel.Connect(second);
    });
    assert(native->snapshots.front().status.value == Models::TunnelStatus::activating);
    return 0;
}
