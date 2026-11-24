// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#include <partout/extensions/ProfileExtensions.h>
#include <algorithm>
#include <type_traits>

namespace {
std::optional<std::string> ModuleId(const Partout::Models::TaggedModule &module) {
    return std::visit([](const auto &tagged) -> std::optional<std::string> {
        using Tagged = std::decay_t<decltype(tagged)>;
        if constexpr (std::is_same_v<Tagged, Partout::Models::TaggedModuleCustom>) {
            return std::nullopt;
        } else {
            return tagged.value.id;
        }
    }, module);
}
}

using namespace Partout;

Models::TaggedProfile Partout::Profile::PrepareInteractive(
    const Models::TaggedProfile &profile, const CredentialPrompt &prompt
) {
    auto prepared = profile;
    for (auto &module : prepared.modules) {
        const auto id = ModuleId(module);
        if (!id || std::find(profile.activeModulesIds.begin(), profile.activeModulesIds.end(),
                            *id) == profile.activeModulesIds.end()) continue;
        module = Module::PrepareInteractive(module, prompt);
    }
    return prepared;
}
