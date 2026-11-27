// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include <partout/Runtime.h>
#include <partout/models/ABIEnvelope.h>
#include <partout.h>
#include <portable/common.h>
#include <memory>
#include <stdexcept>

namespace Partout::Runtime {
std::string Version() {
    return partout_version();
}

void Initialize(const InitializationOptions &options) {
    partout_init_args args{};
    args.log_level = static_cast<int>(options.log_level);
    args.logs_private_data = options.logs_private_data;
    args.logger_fn = options.logger_fn;
    args.logger_ctx = options.logger_ctx;
    partout_init(&args);
}

Models::TaggedProfile ImportProfile(
    const std::string &text,
    const std::optional<std::string> &name,
    const std::optional<std::string> &profile_id
) {
    try {
        std::unique_ptr<char, decltype(&pp_free)> json(
            partout_import_profile(text.c_str(), profile_id ? profile_id->c_str() : nullptr,
                                   name ? name->c_str() : nullptr), &pp_free
        );
        if (!json) throw std::runtime_error("Import failed");
        const auto envelope = Models::ABIEnvelope::FromJson(Json::Parse(json.get()));
        // FIXME: ### Interpret ABIEnvelope errors as fully as Swift/Kotlin and expose typed C++ errors.
        if (envelope.code || !envelope.payload) throw std::runtime_error("Import failed");
        return Models::TaggedProfile::FromJson(*envelope.payload);
    } catch (...) {
        // FIXME: ### Preserve structured ABI errors and distinguish decoding failures while keeping configuration data private.
        throw std::runtime_error("Partout could not import this configuration.");
    }
}

std::optional<std::string> WireGuardPublicKey(const std::string &private_key) {
    std::unique_ptr<char, decltype(&pp_free)> key(partout_wireguard_pubkey(private_key.c_str()), &pp_free);
    if (!key) return std::nullopt;
    return std::string(key.get());
}
}
