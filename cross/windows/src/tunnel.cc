// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include <winsock2.h>
#include <ws2ipdef.h>
#include <windows.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include "partout_winrt.h"
#include "tunnel_profile.h"
#include "tunnel_internal.h"
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
#include <limits>

namespace Partout {
namespace {
using namespace winrt::Windows::Networking::Vpn;
using namespace winrt::Windows::Foundation;
struct Apartment {
    Apartment() {
        // WinRT activation factories are cached across workers. Keep their MTA
        // alive for the process lifetime, including after a worker has exited.
        static const auto processApartment = [] {
            CO_MTA_USAGE_COOKIE cookie{};
            winrt::check_hresult(CoIncrementMTAUsage(&cookie));
            return cookie;
        }();
        (void)processApartment;
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
} // namespace
std::optional<std::string> DecodeTunnelProfileId(const winrt::hstring &xml) {
    // The display name is editable and is never the profile identity.
    try {
        if (xml.empty() || xml.size() > 1024 * 1024) return std::nullopt;
        using namespace winrt::Windows::Data::Xml::Dom;
        const XmlLoadSettings settings;
        settings.ProhibitDtd(true);
        settings.ResolveExternals(false);
        settings.MaxElementDepth(8);
        const XmlDocument document;
        document.LoadXml(xml, settings);
        const auto root = document.DocumentElement();
        if (!root || root.TagName() != L"PartoutProfile" || root.GetAttribute(L"version") != L"1")
            return std::nullopt;
        std::wstring json;
        bool hasConnectionDetails = false;
        for (const auto &node : root.ChildNodes()) {
            if (node.NodeType() == NodeType::TextNode || node.NodeType() == NodeType::DataSectionNode) {
                json += node.InnerText();
            } else if (node.NodeType() == NodeType::ElementNode &&
                       node.NodeName() == L"ConnectionDetails" && !hasConnectionDetails) {
                hasConnectionDetails = true;
            } else {
                return std::nullopt;
            }
        }
        const auto decoded = Models::TaggedProfile::FromJson(nlohmann::json::parse(winrt::to_string(json)));
        if (decoded.id.empty()) return std::nullopt;
        return decoded.id;
    } catch (...) {
        // Unrecognized configuration is not ours to modify. Never log payloads.
        return std::nullopt;
    }
}
namespace {
struct OwnedProfile {
    VpnPlugInProfile profile;
    std::string id;
};
std::vector<OwnedProfile> OwnedProfiles(const VpnManagementAgent &agent) {
    const auto family = Family();
    std::vector<OwnedProfile> result;
    for (const auto &item : Await("Enumerate VPN profiles", agent.GetProfilesAsync())) {
        const auto profile = item.try_as<VpnPlugInProfile>();
        if (!profile || profile.VpnPluginPackageFamilyName() != family) continue;
        if (const auto id = DecodeTunnelProfileId(profile.CustomConfiguration())) result.push_back({profile, *id});
    }
    return result;
}
VpnPlugInProfile Find(const VpnManagementAgent &agent, const std::string &id) {
    for (const auto &profile : OwnedProfiles(agent)) {
        if (profile.id == id) return profile.profile;
    }
    return nullptr;
}
std::optional<Models::TunnelSnapshotEnvironment> Environment(const VpnPlugInProfile &profile) {
    // VpnManagementAgent has no counters. Resolve only this VPN's interface;
    // never substitute physical-adapter or machine-wide traffic.
    MIB_IF_ROW2 row{};
    if (ConvertInterfaceAliasToLuid(profile.ProfileName().c_str(), &row.InterfaceLuid) != NO_ERROR ||
        GetIfEntry2(&row) != NO_ERROR) return std::nullopt;
    return TunnelInterfaceEnvironment(row);
}
} // namespace
std::optional<Models::TunnelSnapshotEnvironment> TunnelInterfaceEnvironment(const MIB_IF_ROW2 &row) {
    if (row.OperStatus != IfOperStatusUp || (row.Type != IF_TYPE_PPP && row.Type != IF_TYPE_TUNNEL))
        return std::nullopt;
    const auto maximum = static_cast<ULONG64>(std::numeric_limits<int64_t>::max());
    if (row.InOctets > maximum || row.OutOctets > maximum) return std::nullopt;
    Models::TunnelSnapshotEnvironment environment{};
    environment.connectionStatus.value = Models::ConnectionStatus::connected;
    environment.dataCount.received = static_cast<int64_t>(row.InOctets);
    environment.dataCount.sent = static_cast<int64_t>(row.OutOctets);
    return environment;
}
namespace {
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

Tunnel::Tunnel() {
    winrt_log(WinrtLogInfo, "Partout::Tunnel initialized\n");
}

std::vector<Models::TunnelSnapshot> Tunnel::Fetch() {
    return WithAgent("Fetch profiles", [&](const auto &agent) {
        std::vector<Models::TunnelSnapshot> result;
        for (const auto &owned : OwnedProfiles(agent)) {
            const auto &profile = owned.profile;
            Models::TunnelSnapshot info{};
            info.id = owned.id;
            switch (profile.ConnectionStatus()) {
                case VpnManagementConnectionStatus::Disconnected: info.status.value = Models::TunnelStatus::inactive; break;
                case VpnManagementConnectionStatus::Connecting: info.status.value = Models::TunnelStatus::activating; break;
                case VpnManagementConnectionStatus::Connected: info.status.value = Models::TunnelStatus::active; break;
                case VpnManagementConnectionStatus::Disconnecting: info.status.value = Models::TunnelStatus::deactivating; break;
                default: throw std::runtime_error("Windows returned an unknown VPN status.");
            }
            info.isEnabled = info.status.value != Models::TunnelStatus::inactive;
            if (info.status.value == Models::TunnelStatus::active) info.environment = Environment(profile);
            result.push_back(std::move(info));
        }
        return result;
    });
}
void Tunnel::Save(const Models::TaggedProfile &profile) {
    if (profile.id.empty()) throw std::invalid_argument("The profile ID is empty.");
    if (profile.name.empty()) throw std::invalid_argument("The profile name is empty.");
    WithAgent("Save profile", [&](const auto &agent) {
        const auto name = winrt::to_hstring(profile.name);
        VpnPlugInProfile existing{nullptr};
        std::vector<VpnPlugInProfile> previousNames;
        for (const auto &owned : OwnedProfiles(agent)) {
            if (owned.id != profile.id) continue;
            if (owned.profile.ConnectionStatus() != VpnManagementConnectionStatus::Disconnected)
                throw std::runtime_error("Disconnect the VPN before updating its configuration.");
            if (owned.profile.ProfileName() == name) existing = owned.profile;
            else previousNames.push_back(owned.profile);
        }
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
        // Windows identifies updates by entry name. Never update another entry
        // just because its display name matches this profile.
        for (const auto &other : Await("Check VPN profile names", agent.GetProfilesAsync())) {
            if (CompareStringOrdinal(other.ProfileName().c_str(), -1, name.c_str(), -1, TRUE) != CSTR_EQUAL)
                continue;
            const auto plugin = other.try_as<VpnPlugInProfile>();
            if (!plugin || plugin.VpnPluginPackageFamilyName() != Family() ||
                DecodeTunnelProfileId(plugin.CustomConfiguration()) != profile.id)
                throw std::runtime_error("Another Windows VPN profile already uses this name.");
        }
        auto target = existing ? existing : VpnPlugInProfile{};
        target.ProfileName(winrt::to_hstring(profile.name));
        target.VpnPluginPackageFamilyName(Family());
        target.ServerUris().Clear();
        // Required by Windows; Partout obtains actual endpoints from the profile.
        target.ServerUris().Append(Uri(L"https://profile.invalid"));
        target.CustomConfiguration(xml);
        target.RememberCredentials(false);
        // Add the replacement first: if Windows rejects the name/configuration,
        // the old disconnected registration remains available.
        Check("Save VPN profile", existing ? Await("Update VPN profile", agent.UpdateProfileFromObjectAsync(target))
                       : Await("Add VPN profile", agent.AddProfileFromObjectAsync(target)));
        for (const auto &previous : previousNames) {
            Check("Remove renamed VPN profile", Await("Remove renamed VPN profile", agent.DeleteProfileAsync(previous)));
        }
    });
}
void Tunnel::Connect(const std::string &id) {
    WithAgent("Connect profile", [&](const auto &agent) {
        const auto profile = Find(agent, id);
        if (!profile) throw std::runtime_error("The Windows VPN profile is missing.");
        Check("Connect VPN profile", Await("Connect VPN profile", agent.ConnectProfileAsync(profile)));
    });
}
void Tunnel::Disconnect(const std::string &id) {
    WithAgent("Disconnect profile", [&](const auto &agent) {
        const auto profile = Find(agent, id);
        if (!profile || profile.ConnectionStatus() == VpnManagementConnectionStatus::Disconnected) return;
        Check("Disconnect VPN profile", Await("Disconnect VPN profile", agent.DisconnectProfileAsync(profile)));
    });
}
void Tunnel::Remove(const std::string &id) {
    WithAgent("Remove profile", [&](const auto &agent) {
        const auto profile = Find(agent, id);
        if (!profile) return;
        if (profile.ConnectionStatus() != VpnManagementConnectionStatus::Disconnected)
            throw std::runtime_error("The Windows VPN profile is still active.");
        Check("Delete VPN profile", Await("Delete VPN profile", agent.DeleteProfileAsync(profile)));
    });
}
}
