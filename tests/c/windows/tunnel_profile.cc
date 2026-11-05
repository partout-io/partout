// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include "tunnel_profile.h"
#include "partout/models/TaggedProfile.h"
#include <winrt/Windows.Data.Xml.Dom.h>
#include <cassert>

int main() {
    winrt::init_apartment();
    Partout::Models::TaggedProfile profile{};
    profile.id = "stable-id";
    profile.name = "Office & Home";
    using namespace winrt::Windows::Data::Xml::Dom;
    const XmlDocument document;
    const auto root = document.CreateElement(L"PartoutProfile");
    root.SetAttribute(L"version", L"1");
    root.InnerText(winrt::to_hstring(profile.ToJson().dump()));
    document.AppendChild(root);
    assert(Partout::DecodeTunnelProfileId(document.GetXml()) == profile.id);
    profile.name = "Renamed";
    root.InnerText(winrt::to_hstring(profile.ToJson().dump()));
    const auto details = document.CreateElement(L"ConnectionDetails");
    details.InnerText(L"Windows metadata is not profile JSON");
    root.AppendChild(details);
    assert(Partout::DecodeTunnelProfileId(document.GetXml()) == profile.id);
    root.SetAttribute(L"version", L"2");
    assert(!Partout::DecodeTunnelProfileId(document.GetXml()));
    assert(!Partout::DecodeTunnelProfileId(L"malformed"));
    assert(!Partout::DecodeTunnelProfileId(L"<PartoutProfile version='1'>{}</PartoutProfile>"));
    assert(!Partout::DecodeTunnelProfileId(L"<!DOCTYPE x [<!ENTITY a 'secret'>]><PartoutProfile version='1'>&a;</PartoutProfile>"));

}
