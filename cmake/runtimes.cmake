# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

if(NOT PP_BUILD_LIBRARY)
    return()
endif()

set(partout_runtime_targets)
set_source_files_properties(runtimes/platform_stub.c PROPERTIES SKIP_PRECOMPILE_HEADERS ON)

# Wintun uses models internally even without the portable C++ runtime.
if(NOT ANDROID AND (PP_BUILD_CPP_RUNTIME OR PP_BUILD_WINTUN))
    enable_language(CXX)
    if(NOT TARGET nlohmann_json::nlohmann_json)
        include(FetchContent)
        FetchContent_Declare(json
            URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
            URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa
        )
        set(JSON_Install OFF)
        if(partout_install_sdk AND partout_export_cpp_abi)
            set(JSON_Install ON)
        endif()
        FetchContent_MakeAvailable(json)
    endif()
    set(PARTOUT_CPP_ROOT "${CMAKE_CURRENT_LIST_DIR}/../runtimes/cpp")
    set(PARTOUT_CPP_INCLUDE "${PARTOUT_CPP_ROOT}/include")
    file(GLOB model_sources CONFIGURE_DEPENDS "${PARTOUT_CPP_ROOT}/models/*.cc")
    # Model implementations belong to consumers, not the DLL export surface.
    # Keep one object per model so each link pulls only the models it needs.
    add_library(partout-models STATIC ${model_sources})
    add_library(Partout::Models ALIAS partout-models)
    set_target_properties(partout-models PROPERTIES
        UNITY_BUILD OFF
        POSITION_INDEPENDENT_CODE ON
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON)
    target_compile_features(partout-models PUBLIC cxx_std_17)
    target_compile_definitions(partout-models PUBLIC NOMINMAX)
    target_include_directories(partout-models SYSTEM PUBLIC
        "$<BUILD_INTERFACE:${PARTOUT_CPP_INCLUDE}>"
        "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")
    target_link_libraries(partout-models PUBLIC nlohmann_json::nlohmann_json)
    target_precompile_headers(partout-models PRIVATE <partout/Json.h>)
    if(MSVC)
        target_compile_options(partout-models PRIVATE /EHsc /permissive- /W4)
        set_target_properties(partout-models PROPERTIES
            MSVC_RUNTIME_LIBRARY MultiThreadedDLL MSVC_RUNTIME_CHECKS "")
    endif()
endif()

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
        # The portable allocation helpers use Clang nullability annotations.
        target_compile_definitions(partout-cpp-runtime PRIVATE _Nullable= _Nonnull=)
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
    )
    target_include_directories(partout-wintun-runtime PRIVATE src/c/portable/include "${WINTUN_DIR}")
    target_link_libraries(partout-wintun-runtime PUBLIC Partout::Headers PRIVATE ole32)
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
