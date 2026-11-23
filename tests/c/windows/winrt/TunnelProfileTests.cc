// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#include "TunnelProfile.h"
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
    root.InnerText(winrt::to_hstring(profile.ToJson().Encode()));
    document.AppendChild(root);
    assert(Partout::WinRT::Profiles::DecodeId(document.GetXml()) == profile.id);
    profile.name = "Renamed";
    root.InnerText(winrt::to_hstring(profile.ToJson().Encode()));
    const auto details = document.CreateElement(L"ConnectionDetails");
    details.InnerText(L"Windows metadata is not profile JSON");
    root.AppendChild(details);
    assert(Partout::WinRT::Profiles::DecodeId(document.GetXml()) == profile.id);
    root.SetAttribute(L"version", L"2");
    assert(!Partout::WinRT::Profiles::DecodeId(document.GetXml()));
    assert(!Partout::WinRT::Profiles::DecodeId(L"malformed"));
    assert(!Partout::WinRT::Profiles::DecodeId(L"<PartoutProfile version='1'>{}</PartoutProfile>"));
    assert(!Partout::WinRT::Profiles::DecodeId(L"<!DOCTYPE x [<!ENTITY a 'secret'>]><PartoutProfile version='1'>&a;</PartoutProfile>"));
}
