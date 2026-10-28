// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <nlohmann/json.hpp>
#include <cmath>
#include <limits>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <variant>

namespace Partout::Models {

// C ABI string enums arrive as unquoted tokens, rather than JSON documents.
// Keep invalid input and decoding failures inside the noexcept callback boundary.
template<typename T>
std::optional<T> TryReadStringEnum(const char *token) noexcept {
    if (!token) return std::nullopt;
    try {
        return T::FromJson(nlohmann::json(token));
    } catch (...) {
        return std::nullopt;
    }
}

// nlohmann's default integer conversion truncates fractions and wraps overflow.
// Keep representation checks generic and separate from platform-specific limits.
template<typename T>
void ReadJsonValue(const nlohmann::json &json, T &value) {
    if constexpr (!std::is_integral_v<T> || std::is_same_v<T, bool>) {
        json.get_to(value);
    } else {
        if (json.is_number_unsigned()) {
            const auto raw = json.get_ref<const nlohmann::json::number_unsigned_t &>();
            if (raw > static_cast<nlohmann::json::number_unsigned_t>(std::numeric_limits<T>::max()))
                throw std::invalid_argument("JSON integer is out of range");
            value = static_cast<T>(raw);
            return;
        }
        if (json.is_number_integer()) {
            const auto raw = json.get_ref<const nlohmann::json::number_integer_t &>();
            if constexpr (std::is_unsigned_v<T>) {
                if (raw < 0 || static_cast<nlohmann::json::number_unsigned_t>(raw) >
                    std::numeric_limits<T>::max())
                    throw std::invalid_argument("JSON integer is out of range");
            } else {
                if (raw < std::numeric_limits<T>::lowest() || raw > std::numeric_limits<T>::max())
                    throw std::invalid_argument("JSON integer is out of range");
            }
            value = static_cast<T>(raw);
            return;
        }
        if (!json.is_number_float()) throw std::invalid_argument("Expected a JSON integer");
        const auto raw = json.get_ref<const nlohmann::json::number_float_t &>();
        const auto upper = std::ldexp(1.0, std::numeric_limits<T>::digits);
        const auto lower = std::is_signed_v<T> ? -upper : 0.0;
        if (!std::isfinite(raw) || raw != std::floor(raw) || raw < lower || raw >= upper)
            throw std::invalid_argument("JSON number is not a representable integer");
        value = static_cast<T>(raw);
    }
}

template<typename T>
bool ValidateModel(const T &value, std::stringstream &errors, const std::string &path) {
    return value.Validate(errors, path);
}

template<typename... T>
bool ValidateModel(const std::variant<T...> &value, std::stringstream &errors,
                   const std::string &path) {
    return std::visit([&](const auto &model) {
        return ValidateModel(model, errors, path);
    }, value);
}

} // namespace Partout::Models
