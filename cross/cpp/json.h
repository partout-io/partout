// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#pragma once
#include <nlohmann/json.hpp>
#include <cmath>
#include <limits>
#include <map>
#include <vector>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <variant>
#include <utility>

namespace Partout::Models {

// Application-facing JSON value. The backend and its exceptions stay behind this API.
class Json {
    template<typename Operation>
    static auto TranslateErrors(Operation operation) -> decltype(operation()) {
        try {
            return operation();
        } catch (const nlohmann::json::exception &error) {
            throw Error(error.what());
        }
    }
public:
    class Error : public std::runtime_error {
    public:
        using std::runtime_error::runtime_error;
    };
    Json() = default;
    template<typename T, std::enable_if_t<!std::is_same_v<std::decay_t<T>, nlohmann::json>, int> = 0>
    Json(const T &value) {
        TranslateErrors([&] {
            value_ = value;
        });
    }
    Json(std::initializer_list<std::pair<const std::string, Json>> members) {
        value_ = nlohmann::json::object();
        for (const auto &member : members) value_[member.first] = member.second.value_;
    }
    static Json Parse(const std::string &text) {
        return TranslateErrors([&] {
            return Json(nlohmann::json::parse(text));
        });
    }
    static Json Array() {
        return Json(nlohmann::json::array());
    }
    std::string Encode() const {
        return TranslateErrors([&] {
            return value_.dump();
        });
    }
    template<typename T> T Get() const;
    bool IsNull() const {
        return value_.is_null();
    }
    bool IsObject() const {
        return value_.is_object();
    }
    bool IsArray() const {
        return value_.is_array();
    }
    bool IsString() const {
        return value_.is_string();
    }
    bool IsNumber() const {
        return value_.is_number();
    }
    bool IsPrimitive() const {
        return value_.is_primitive();
    }
    std::size_t Size() const {
        return value_.size();
    }
    Json At(const std::string &key) const {
        return TranslateErrors([&] {
            return Json(value_.at(key));
        });
    }
    std::optional<Json> Find(const std::string &key) const {
        const auto found = value_.find(key);
        if (found == value_.end()) return std::nullopt;
        return Json(*found);
    }
    template<typename T> T Value(const std::string &key, const T &fallback) const {
        if (!IsObject()) throw Error("Expected JSON object");
        const auto found = Find(key);
        return found ? found->Get<T>() : fallback;
    }
    void Set(const std::string &key, const Json &value) {
        TranslateErrors([&] {
            value_[key] = value.value_;
        });
    }
    void Append(const Json &value) {
        TranslateErrors([&] {
            value_.push_back(value.value_);
        });
    }
    void Merge(const Json &value) {
        TranslateErrors([&] {
            value_.update(value.value_);
        });
    }
    std::vector<Json> Elements() const {
        if (!IsArray()) throw Error("Expected JSON array");
        std::vector<Json> result;
        result.reserve(value_.size());
        for (const auto &value : value_) result.push_back(Json(value));
        return result;
    }
    std::map<std::string, Json> Members() const {
        if (!IsObject()) throw Error("Expected JSON object");
        std::map<std::string, Json> result;
        for (const auto &entry : value_.items()) result.emplace(entry.key(), Json(entry.value()));
        return result;
    }
    bool operator==(const Json &other) const {
        return value_ == other.value_;
    }
    bool operator!=(const Json &other) const {
        return !(*this == other);
    }
private:
    explicit Json(nlohmann::json value) : value_(std::move(value)) {}
    nlohmann::json value_;
    friend void to_json(nlohmann::json &json, const Json &value) {
        json = value.value_;
    }
    friend void from_json(const nlohmann::json &json, Json &value) {
        value.value_ = json;
    }
};

// C ABI string enums arrive as unquoted tokens, rather than JSON documents.
// Keep invalid input and decoding failures inside the noexcept callback boundary.
template <typename T> std::optional<T> TryReadStringEnum(const char *token) noexcept {
    if (!token) return std::nullopt;
    try {
        return T::FromJson(Json(token));
    } catch (...) {
        return std::nullopt;
    }
}

// nlohmann's default integer conversion truncates fractions and wraps overflow.
// Keep representation checks generic and separate from platform-specific limits.
template <typename T> void ReadJsonValue(const nlohmann::json &json, T &value) {
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

template<typename T> T Json::Get() const {
    return TranslateErrors([&] {
        T result{};
        ReadJsonValue(value_, result);
        return result;
    });
}

template <typename T>
bool ValidateModel(const T &value, std::stringstream &errors, const std::string &path) {
    return value.Validate(errors, path);
}

template <typename... T>
bool ValidateModel(const std::variant<T...> &value, std::stringstream &errors,
                   const std::string &path) {
    return std::visit(
        [&](const auto &model) {
            return ValidateModel(model, errors, path);
        },
        value);
}

} // namespace Partout::Models
