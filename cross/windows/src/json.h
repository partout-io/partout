// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <nlohmann/json.hpp>
#include <sstream>
#include <string>

namespace Partout::Models {

// Discriminator envelopes must retain their entire payload. Concrete tagged
// variants remain available as generated model types.
struct JSONValue {
    nlohmann::json value;

    bool Validate(std::stringstream &, const std::string &) const {
        return true;
    }

    bool operator==(const JSONValue &other) const {
        return value == other.value;
    }

    bool operator!=(const JSONValue &other) const {
        return !(*this == other);
    }
};

inline void to_json(nlohmann::json &json, const JSONValue &value) {
    json = value.value;
}

inline void from_json(const nlohmann::json &json, JSONValue &value) {
    value.value = json;
}

} // namespace Partout::Models
