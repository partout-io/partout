// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include <partout/models/TaggedProfile.h>
#include <partout/models/TunnelSnapshot.h>
#include "TunnelCredentials.h"
#include <map>
#include <memory>
#include <stdexcept>

namespace Partout {
class TunnelStrategy {
public:
    virtual ~TunnelStrategy() = default;
    // All calls run on the same background worker, never the UI thread.
    virtual std::vector<Models::TunnelSnapshot> Fetch() = 0;
    virtual std::map<std::string, std::string> ObservationErrors() const {
        return {};
    }

    virtual void Save(const Models::TaggedProfile &profile) = 0;
    virtual void Connect(const std::string &id) = 0;
    virtual void ConnectWithCredentials(const std::string &, const TunnelCredentials &) {
        throw std::runtime_error("Interactive login is unavailable for this tunnel strategy.");
    }

    virtual void Disconnect(const std::string &id) = 0;
    virtual void Remove(const std::string &id) = 0;
    // Called from the shutdown thread before joining the serialized worker.
    virtual void Cancel() noexcept {}
};

// Selects the native backend; unsupported platforms report unavailable control.
namespace TunnelStrategies {
std::unique_ptr<TunnelStrategy> MakeNative(const std::string &serverUri);
}
}
