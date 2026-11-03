// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <windows.h>
#include "partout_winrt.h"
#include "models/TaggedProfile.h"
#include "models/TunnelSnapshot.h"
#include "winrt/log.h"
#include <appmodel.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.Vpn.h>
#include <chrono>
#include <stdexcept>
#include <sstream>
#include <iomanip>

namespace Partout {
namespace {
using namespace winrt::Windows::Networking::Vpn;
using namespace winrt::Windows::Foundation;
struct Apartment {
    Apartment() {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
    }
    ~Apartment() {
        winrt::uninit_apartment();
    }
};

std::runtime_error WindowsError(const char *operation, winrt::hresult code) {
    std::ostringstream message;
    message << operation << " failed (HRESULT=0x" << std::hex << std::uppercase
            << std::setw(8) << std::setfill('0') << static_cast<unsigned>(code.value) << ").";
    return std::runtime_error(message.str());
}
template<typename Operation>
auto Await(const char *name, const Operation &operation) {
    try {
        if (operation.wait_for(std::chrono::seconds(60)) == AsyncStatus::Started) {
            operation.Cancel();
            throw std::runtime_error(std::string(name) + " timed out.");
        }
        return operation.get();
    } catch (const winrt::hresult_error &error) {
        throw WindowsError(name, error.code());
    }
}
void Check(const char *operation, VpnManagementErrorStatus status) {
    if (status != VpnManagementErrorStatus::Ok)
        throw std::runtime_error(std::string(operation) + " rejected (VpnManagementErrorStatus=" +
                                 std::to_string(static_cast<int>(status)) + ").");
}
winrt::hstring Family() {
    UINT32 length = 0;
    auto result = GetCurrentPackageFamilyName(&length, nullptr);
    if (result != ERROR_INSUFFICIENT_BUFFER)
        throw std::runtime_error("Package identity unavailable (Win32 " + std::to_string(result) + ").");
    std::wstring family(length, L'\0');
    result = GetCurrentPackageFamilyName(&length, family.data());
    if (result != ERROR_SUCCESS)
        throw std::runtime_error("Unable to read package identity (Win32 " + std::to_string(result) + ").");
    family.resize(length - 1);
    return winrt::hstring(family);
}
std::wstring Name(const std::wstring &prefix, const std::string &id) {
    return prefix + winrt::to_hstring(id).c_str();
}
std::vector<VpnPlugInProfile> OwnedProfiles(const VpnManagementAgent &agent, const std::wstring &prefix) {
    const auto family = Family();
    std::vector<VpnPlugInProfile> result;
    for (const auto &item : Await("Enumerate VPN profiles", agent.GetProfilesAsync())) {
        const auto profile = item.try_as<VpnPlugInProfile>();
        if (!profile || profile.VpnPluginPackageFamilyName() != family) continue;
        const auto name = profile.ProfileName();
        if (std::wstring_view(name).substr(0, prefix.size()) == prefix) result.push_back(profile);
    }
    return result;
}
VpnPlugInProfile Find(const VpnManagementAgent &agent, const std::wstring &prefix, const std::string &id) {
    for (const auto &profile : OwnedProfiles(agent, prefix)) {
        if (profile.ProfileName() == Name(prefix, id)) return profile;
    }
    return nullptr;
}
template<typename Action>
auto WithAgent(const char *operation, Action action) {
    try {
        Apartment apartment;
        return action(VpnManagementAgent{});
    } catch (const winrt::hresult_error &error) {
        // WinRT messages can echo custom configuration. Report only stage/code.
        throw WindowsError(operation, error.code());
    }
}

} // namespace

extern "C" void pp_winrt_tunnel_link() {}

Tunnel::Tunnel(const std::wstring &profilePrefix) : prefix_(profilePrefix) {
    if (prefix_.empty()) throw std::invalid_argument("A VPN profile prefix is required.");
    winrt_log(WinrtLogInfo, "Partout::Tunnel initialized\n");
}

std::vector<Models::TunnelSnapshot> Tunnel::Fetch() {
    return WithAgent("Fetch profiles", [&](const auto &agent) {
        std::vector<Models::TunnelSnapshot> result;
        for (const auto &profile : OwnedProfiles(agent, prefix_)) {
            Models::TunnelSnapshot info{};
            info.id = winrt::to_string(std::wstring_view(profile.ProfileName()).substr(prefix_.size()));
            switch (profile.ConnectionStatus()) {
                case VpnManagementConnectionStatus::Disconnected: info.status.value = Models::TunnelStatus::inactive; break;
                case VpnManagementConnectionStatus::Connecting: info.status.value = Models::TunnelStatus::activating; break;
                case VpnManagementConnectionStatus::Connected: info.status.value = Models::TunnelStatus::active; break;
                case VpnManagementConnectionStatus::Disconnecting: info.status.value = Models::TunnelStatus::deactivating; break;
                default: throw std::runtime_error("Windows returned an unknown VPN status.");
            }
            info.isEnabled = info.status.value != Models::TunnelStatus::inactive;
            // Management APIs do not expose Partout transfer counters/errors.
            // Leave them absent instead of reporting fabricated zero values.
            result.push_back(std::move(info));
        }
        return result;
    });
}
void Tunnel::Save(const Models::TaggedProfile &profile) {
    if (profile.id.empty()) throw std::invalid_argument("The profile ID is empty.");
    WithAgent("Save profile", [&](const auto &agent) {
        auto existing = Find(agent, prefix_, profile.id);
        if (existing && existing.ConnectionStatus() != VpnManagementConnectionStatus::Disconnected)
            throw std::runtime_error("Disconnect the VPN before updating its configuration.");
        using namespace winrt::Windows::Data::Xml::Dom;
        const XmlDocument document;
        auto root = document.CreateElement(L"PartoutProfile");
        root.SetAttribute(L"version", L"1");
        try {
            root.InnerText(winrt::to_hstring(profile.ToJson().dump()));
        } catch (const nlohmann::json::exception &) {
            throw std::runtime_error("Unable to encode the VPN profile.");
        }
        document.AppendChild(root);
        const auto xml = document.GetXml();
        if (xml.size() > 1024 * 1024)
            throw std::runtime_error("The encoded VPN configuration exceeds 1 MiB.");
        auto target = existing ? existing : VpnPlugInProfile{};
        target.ProfileName(Name(prefix_, profile.id));
        target.VpnPluginPackageFamilyName(Family());
        target.ServerUris().Clear();
        // Required by Windows; Partout obtains actual endpoints from the profile.
        target.ServerUris().Append(Uri(L"https://profile.invalid"));
        target.CustomConfiguration(xml);
        target.RememberCredentials(false);
        Check("Save VPN profile", existing ? Await("Update VPN profile", agent.UpdateProfileFromObjectAsync(target))
                       : Await("Add VPN profile", agent.AddProfileFromObjectAsync(target)));
    });
}
void Tunnel::Connect(const std::string &id) {
    WithAgent("Connect profile", [&](const auto &agent) {
        const auto profile = Find(agent, prefix_, id);
        if (!profile) throw std::runtime_error("The Windows VPN profile is missing.");
        Check("Connect VPN profile", Await("Connect VPN profile", agent.ConnectProfileAsync(profile)));
    });
}
void Tunnel::Disconnect(const std::string &id) {
    WithAgent("Disconnect profile", [&](const auto &agent) {
        const auto profile = Find(agent, prefix_, id);
        if (!profile || profile.ConnectionStatus() == VpnManagementConnectionStatus::Disconnected) return;
        Check("Disconnect VPN profile", Await("Disconnect VPN profile", agent.DisconnectProfileAsync(profile)));
    });
}
void Tunnel::Remove(const std::string &id) {
    WithAgent("Remove profile", [&](const auto &agent) {
        const auto profile = Find(agent, prefix_, id);
        if (!profile) return;
        if (profile.ConnectionStatus() != VpnManagementConnectionStatus::Disconnected)
            throw std::runtime_error("The Windows VPN profile is still active.");
        Check("Delete VPN profile", Await("Delete VPN profile", agent.DeleteProfileAsync(profile)));
    });
}
}
