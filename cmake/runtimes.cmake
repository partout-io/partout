# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

if(NOT PP_BUILD_LIBRARY)
    return()
endif()

set(partout_runtime_targets)
set_source_files_properties(runtimes/platform_stub.c PROPERTIES SKIP_PRECOMPILE_HEADERS ON)

if(NOT ANDROID AND PP_BUILD_CPP_RUNTIME)
    set(partout_cpp_sources
        "${PARTOUT_CPP_ROOT}/Runtime.cc"
        "${PARTOUT_CPP_ROOT}/extensions/ModuleExtensions.cc"
        "${PARTOUT_CPP_ROOT}/extensions/ProfileExtensions.cc"
        "${PARTOUT_CPP_ROOT}/tunnel/Tunnel.cc")
    add_library(partout-cpp-runtime STATIC ${partout_cpp_sources})
    set_target_properties(partout-cpp-runtime PROPERTIES UNITY_BUILD ON)
    target_compile_features(partout-cpp-runtime PUBLIC cxx_std_17)
    target_compile_definitions(partout-cpp-runtime PUBLIC NOMINMAX)
    target_include_directories(partout-cpp-runtime SYSTEM PUBLIC
        "$<BUILD_INTERFACE:${PARTOUT_CPP_INCLUDE}>"
        "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")
    target_link_libraries(partout-cpp-runtime PUBLIC Partout::Models)
    target_link_libraries(partout-cpp-runtime PRIVATE Partout::Headers)
    target_include_directories(partout-cpp-runtime PRIVATE src/c/portable/include)
    target_precompile_headers(partout-cpp-runtime PRIVATE <partout/Json.h>)
    if(MSVC)
        target_compile_options(partout-cpp-runtime PRIVATE /EHsc /permissive- /W4)
    endif()
    list(APPEND partout_runtime_targets partout-cpp-runtime)
endif()

# Native integration layers are linked into the shared library.
if(PP_BUILD_WINRT)
    if(CMAKE_VERSION VERSION_LESS 4.0)
        message(FATAL_ERROR "PP_BUILD_WINRT requires CMake 4.0 or newer")
    endif()
    if(NOT WIN32 OR NOT MSVC)
        message(FATAL_ERROR "PP_BUILD_WINRT requires MSVC and the Windows SDK")
    endif()

    add_library(partout-winrt-runtime STATIC
        runtimes/platform_stub.c
        runtimes/windows/winrt/VpnChannelRuntime.cc
        runtimes/windows/winrt/WinRTTunnelStrategy.cc
        runtimes/windows/winrt/backend/ABI.cc
        runtimes/windows/winrt/backend/Log.cc
        runtimes/windows/winrt/backend/NetworkMonitor.cc
        runtimes/windows/winrt/backend/Platform.cc
        runtimes/windows/winrt/backend/RuntimeLoop.cc
        runtimes/windows/winrt/backend/Socket.cc
        runtimes/windows/winrt/backend/Tun.cc
        runtimes/windows/winrt/backend/TunnelController.cc
        runtimes/windows/winrt/backend/TunSettings.cc
    )
    target_include_directories(partout-winrt-runtime PUBLIC
        "$<BUILD_INTERFACE:${PARTOUT_CPP_INCLUDE}>"
        "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/runtimes/windows/winrt/include>"
        "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")
    target_include_directories(partout-winrt-runtime PRIVATE src/c/portable/include)
    target_link_libraries(partout-winrt-runtime
        PUBLIC Partout::Headers Partout::Models windowsapp runtimeobject ws2_32 iphlpapi
        PRIVATE ole32)
    target_compile_features(partout-winrt-runtime PUBLIC cxx_std_20)
    target_compile_definitions(partout-winrt-runtime
        PUBLIC NOMINMAX
        PRIVATE WINRT_LEAN_AND_MEAN)
    target_compile_options(partout-winrt-runtime PRIVATE /EHsc /permissive- /W4)
    # Parse the common Windows projections once. Winsock must precede windows.h.
    target_precompile_headers(partout-winrt-runtime PRIVATE
        <winsock2.h>
        <winrt/Windows.Foundation.h>
        <winrt/Windows.Foundation.Collections.h>
        <winrt/Windows.Networking.h>
        <winrt/Windows.Networking.Connectivity.h>
        <winrt/Windows.Networking.Sockets.h>
        <winrt/Windows.Networking.Vpn.h>
        <winrt/Windows.Storage.Streams.h>
        <partout/Json.h>
    )
    list(APPEND partout_runtime_targets partout-winrt-runtime)
elseif(PP_BUILD_WINTUN)
    add_library(partout-wintun-runtime STATIC
        runtimes/windows/wintun/platform.c
        runtimes/windows/wintun/NetworkSettings.cc
    )
    target_include_directories(partout-wintun-runtime PRIVATE
        src/c/portable/include "${WINTUN_DIR}" "${PARTOUT_CPP_INCLUDE}")
    target_compile_definitions(partout-wintun-runtime PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
    target_compile_features(partout-wintun-runtime PRIVATE cxx_std_17)
    target_compile_options(partout-wintun-runtime PRIVATE /EHsc)
    target_link_libraries(partout-wintun-runtime PUBLIC Partout::Headers
        PRIVATE nlohmann_json::nlohmann_json ole32 iphlpapi ws2_32)
    list(APPEND partout_runtime_targets partout-wintun-runtime)
elseif(ANDROID)
    add_library(partout-android-runtime STATIC
        runtimes/platform_stub.c
        runtimes/android/native/jni.c
        runtimes/android/native/partout_jni.c
        runtimes/android/native/platform.c
    )
    set_target_properties(partout-android-runtime PROPERTIES
        C_VISIBILITY_PRESET hidden
    )
    target_include_directories(partout-android-runtime PRIVATE src)
    target_link_libraries(partout-android-runtime PUBLIC Partout::Headers PRIVATE android log)
    list(APPEND partout_runtime_targets partout-android-runtime)
elseif(UNIX)
    add_library(partout-posix-runtime STATIC
        runtimes/posix/platform.c
    )
    target_link_libraries(partout-posix-runtime PUBLIC Partout::Headers)
    list(APPEND partout_runtime_targets partout-posix-runtime)
endif()
