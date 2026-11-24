# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

if(PP_BUILD_CPP_RUNTIME OR PP_BUILD_WINRT)
    enable_language(CXX)
    if(NOT TARGET nlohmann_json::nlohmann_json)
        include(FetchContent)
        FetchContent_Declare(json
            URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
            URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa
        )
        set(JSON_Install ${partout_install_sdk})
        FetchContent_MakeAvailable(json)
    endif()
    set(PARTOUT_CPP_ROOT "${CMAKE_CURRENT_LIST_DIR}/../runtimes/cpp")
    set(PARTOUT_CPP_INCLUDE "${PARTOUT_CPP_ROOT}/include")
    file(GLOB model_sources CONFIGURE_DEPENDS "${PARTOUT_CPP_ROOT}/models/*.cc")
    set(partout_cpp_sources ${model_sources}
        "${PARTOUT_CPP_ROOT}/extensions/ModuleExtensions.cc"
        "${PARTOUT_CPP_ROOT}/extensions/ProfileExtensions.cc"
        "${PARTOUT_CPP_ROOT}/tunnel/Tunnel.cc")
    if(PP_BUILD_LIBRARY AND PP_BUILD_WINRT)
        add_library(partout-cpp-runtime INTERFACE)
        target_link_libraries(partout-cpp-runtime INTERFACE Partout::WinRTRuntime)
    else()
        add_library(partout-cpp-runtime STATIC ${partout_cpp_sources})
        set_target_properties(partout-cpp-runtime PROPERTIES UNITY_BUILD ON)
        target_compile_features(partout-cpp-runtime PUBLIC cxx_std_17)
        target_compile_definitions(partout-cpp-runtime PUBLIC NOMINMAX)
        target_include_directories(partout-cpp-runtime SYSTEM PUBLIC
            "$<BUILD_INTERFACE:${PARTOUT_CPP_INCLUDE}>"
            "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")
        target_link_libraries(partout-cpp-runtime PUBLIC nlohmann_json::nlohmann_json)
        if(MSVC)
            target_compile_options(partout-cpp-runtime PRIVATE /EHsc /permissive- /W4)
        endif()
    endif()
    add_library(Partout::CppRuntime ALIAS partout-cpp-runtime)
endif()

if(NOT PP_BUILD_LIBRARY)
    return()
endif()

# Native integration layers consume the public core ABI.
if(PP_BUILD_WINRT)
    if(CMAKE_VERSION VERSION_LESS 4.0)
        message(FATAL_ERROR "PP_BUILD_WINRT requires CMake 4.0 or newer")
    endif()
    if(NOT WIN32 OR NOT MSVC)
        message(FATAL_ERROR "PP_BUILD_WINRT requires MSVC and the Windows SDK")
    endif()

    add_library(partout-winrt-runtime SHARED ${partout_cpp_sources}
        runtimes/windows/winrt/Platform.cc
        runtimes/windows/winrt/VpnChannelRuntime.cc
        runtimes/windows/winrt/WinRTTunnelStrategy.cc
        runtimes/windows/winrt/backend/ABI.cc
        runtimes/windows/winrt/backend/Log.cc
        runtimes/windows/winrt/backend/NetworkMonitor.cc
        runtimes/windows/winrt/backend/RuntimeLoop.cc
        runtimes/windows/winrt/backend/Socket.cc
        runtimes/windows/winrt/backend/Tun.cc
        runtimes/windows/winrt/backend/TunnelController.cc
        runtimes/windows/winrt/backend/TunSettings.cc
    )
    add_library(Partout::WinRTRuntime ALIAS partout-winrt-runtime)
    target_include_directories(partout-winrt-runtime PUBLIC
        "$<BUILD_INTERFACE:${PARTOUT_CPP_INCLUDE}>"
        "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/runtimes/windows/winrt/include>"
        "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")
    target_include_directories(partout-winrt-runtime PRIVATE src/c/portable/include)
    target_link_libraries(partout-winrt-runtime
        PUBLIC Partout::Core nlohmann_json::nlohmann_json windowsapp runtimeobject ws2_32 iphlpapi
        PRIVATE ole32)
    target_compile_features(partout-winrt-runtime PUBLIC cxx_std_20)
    target_compile_definitions(partout-winrt-runtime
        PUBLIC NOMINMAX
        PRIVATE PARTOUT_API_BUILD_DLL WINRT_LEAN_AND_MEAN
        INTERFACE PARTOUT_API_USE_DLL)
    target_compile_options(partout-winrt-runtime PRIVATE /EHsc /permissive- /W4)
    set_target_properties(partout-winrt-runtime PROPERTIES
        OUTPUT_NAME partout-runtime
        WINDOWS_EXPORT_ALL_SYMBOLS ON
        RUNTIME_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/bin/$<0:>"
        ARCHIVE_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/lib/$<0:>"
        MSVC_RUNTIME_LIBRARY MultiThreadedDLL
        MSVC_RUNTIME_CHECKS "")
elseif(PP_BUILD_WINTUN)
    add_library(partout-wintun-runtime STATIC
        runtimes/windows/wintun/platform.c
    )
    add_library(Partout::WintunRuntime ALIAS partout-wintun-runtime)
    target_include_directories(partout-wintun-runtime PRIVATE src/c/portable/include "${WINTUN_DIR}")
    target_link_libraries(partout-wintun-runtime PUBLIC Partout::Core PRIVATE ole32)
    set_target_properties(partout-wintun-runtime PROPERTIES MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
elseif(ANDROID)
    add_library(partout-android-runtime OBJECT
        runtimes/android/native/platform.c
        runtimes/android/native/jni.c
        runtimes/android/native/partout_jni.c
    )
    add_library(Partout::AndroidRuntime ALIAS partout-android-runtime)
    set_target_properties(partout-android-runtime PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        C_VISIBILITY_PRESET hidden
    )
    target_include_directories(partout-android-runtime PRIVATE src)
    target_link_libraries(partout-android-runtime PUBLIC Partout::Core android log)
elseif(UNIX)
    add_library(partout-posix-runtime STATIC
        runtimes/posix/platform.c
    )
    add_library(Partout::POSIXRuntime ALIAS partout-posix-runtime)
    target_link_libraries(partout-posix-runtime PUBLIC Partout::Core)
endif()

# Desktop consumers link the runtime selected by the platform configuration.
if(TARGET Partout::WinRTRuntime)
    set(partout_selected_runtime Partout::WinRTRuntime)
elseif(TARGET Partout::WintunRuntime)
    set(partout_selected_runtime Partout::WintunRuntime)
elseif(TARGET Partout::POSIXRuntime)
    set(partout_selected_runtime Partout::POSIXRuntime)
else()
    return()
endif()
add_library(partout-runtime INTERFACE)
add_library(Partout::Runtime ALIAS partout-runtime)
target_link_libraries(partout-runtime INTERFACE ${partout_selected_runtime})
if(TARGET partout-cpp-runtime AND NOT TARGET partout-winrt-runtime)
    target_link_libraries(partout-runtime INTERFACE Partout::CppRuntime)
endif()
