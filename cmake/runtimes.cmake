# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

# Embed static implementations once; public component targets select the same DLL/DSO.
function(partout_embed_runtime target name)
    set_target_properties(${target} PROPERTIES POSITION_INDEPENDENT_CODE ON)
    target_link_libraries(partout PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,${target}>")
    foreach(property IN ITEMS INCLUDE_DIRECTORIES COMPILE_FEATURES COMPILE_DEFINITIONS LINK_LIBRARIES)
        get_target_property(requirements ${target} INTERFACE_${property})
        if(requirements)
            set_property(TARGET partout APPEND PROPERTY INTERFACE_${property} "${requirements}")
        endif()
    endforeach()
    if(MSVC)
        target_compile_definitions(${target} PRIVATE PARTOUT_API_BUILD_DLL)
        set_target_properties(${target} PROPERTIES
            MSVC_RUNTIME_LIBRARY MultiThreadedDLL MSVC_RUNTIME_CHECKS "")
        target_compile_definitions(partout INTERFACE PARTOUT_API_USE_DLL)
    endif()
    add_library(${target}-interface INTERFACE)
    add_library(Partout::${name} ALIAS ${target}-interface)
    target_link_libraries(${target}-interface INTERFACE Partout::Partout)
    set_target_properties(${target}-interface PROPERTIES EXPORT_NAME ${name})
    if(partout_install_sdk)
        install(TARGETS ${target}-interface EXPORT PartoutTargets)
    endif()
endfunction()

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
    if(PP_BUILD_LIBRARY)
        partout_embed_runtime(partout-cpp-runtime CppRuntime)
        set_target_properties(partout PROPERTIES LINKER_LANGUAGE CXX)
    else()
        add_library(Partout::CppRuntime ALIAS partout-cpp-runtime)
    endif()
endif()

if(NOT PP_BUILD_LIBRARY)
    return()
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
    target_include_directories(partout-winrt-runtime PUBLIC
        "$<BUILD_INTERFACE:${PARTOUT_CPP_INCLUDE}>"
        "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/runtimes/windows/winrt/include>"
        "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")
    target_include_directories(partout-winrt-runtime PRIVATE src/c/portable/include)
    target_link_libraries(partout-winrt-runtime
        PUBLIC Partout::Headers nlohmann_json::nlohmann_json windowsapp runtimeobject ws2_32 iphlpapi
        PRIVATE ole32)
    target_compile_features(partout-winrt-runtime PUBLIC cxx_std_20)
    target_compile_definitions(partout-winrt-runtime
        PUBLIC NOMINMAX
        PRIVATE WINRT_LEAN_AND_MEAN)
    target_compile_options(partout-winrt-runtime PRIVATE /EHsc /permissive- /W4)
    partout_embed_runtime(partout-winrt-runtime WinRTRuntime)
elseif(PP_BUILD_WINTUN)
    add_library(partout-wintun-runtime STATIC
        runtimes/windows/wintun/platform.c
    )
    target_include_directories(partout-wintun-runtime PRIVATE src/c/portable/include "${WINTUN_DIR}")
    target_link_libraries(partout-wintun-runtime PUBLIC Partout::Headers PRIVATE ole32)
    partout_embed_runtime(partout-wintun-runtime WintunRuntime)
elseif(ANDROID)
    add_library(partout-android-runtime STATIC
        runtimes/android/native/platform.c
        runtimes/android/native/jni.c
        runtimes/android/native/partout_jni.c
    )
    set_target_properties(partout-android-runtime PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        C_VISIBILITY_PRESET hidden
    )
    target_include_directories(partout-android-runtime PRIVATE src)
    target_link_libraries(partout-android-runtime PUBLIC Partout::Headers PRIVATE android log)
    partout_embed_runtime(partout-android-runtime AndroidRuntime)
elseif(UNIX)
    add_library(partout-posix-runtime STATIC
        runtimes/posix/platform.c
    )
    target_link_libraries(partout-posix-runtime PUBLIC Partout::Headers)
    partout_embed_runtime(partout-posix-runtime POSIXRuntime)
endif()

# Consumers link the runtime selected by the platform configuration.
if(TARGET Partout::WinRTRuntime)
    set(partout_selected_runtime Partout::WinRTRuntime)
elseif(TARGET Partout::WintunRuntime)
    set(partout_selected_runtime Partout::WintunRuntime)
elseif(TARGET Partout::AndroidRuntime)
    set(partout_selected_runtime Partout::AndroidRuntime)
elseif(TARGET Partout::POSIXRuntime)
    set(partout_selected_runtime Partout::POSIXRuntime)
else()
    return()
endif()
add_library(partout-runtime INTERFACE)
add_library(Partout::Runtime ALIAS partout-runtime)
target_link_libraries(partout-runtime INTERFACE ${partout_selected_runtime})
