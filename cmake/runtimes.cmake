# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

if(NOT PP_BUILD_LIBRARY)
    return()
endif()

# Native integration layers consume the public core ABI.
if(TARGET partout-winrt-backend)
    add_library(partout-bindings STATIC
        runtimes/windows/winrt/Tunnel.cc
        runtimes/windows/winrt/VpnChannelRuntime.cc
        runtimes/windows/winrt/Platform.cc
    )
    add_library(Partout::WinRTRuntime ALIAS partout-bindings)
    target_include_directories(partout-bindings
        PUBLIC
            "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/runtimes/windows/winrt/include>"
            "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
        PRIVATE src
    )
    target_compile_features(partout-bindings PUBLIC cxx_std_20)
    target_compile_definitions(partout-bindings PRIVATE NOMINMAX WINRT_LEAN_AND_MEAN PARTOUT_WINRT_USE_DLL)
    target_compile_options(partout-bindings PRIVATE /EHsc /permissive- /W4)
    # AppContainer consumers use a CRT without the /RTC helpers.
    set_target_properties(partout-bindings PROPERTIES
        MSVC_RUNTIME_LIBRARY MultiThreadedDLL
        MSVC_RUNTIME_CHECKS ""
    )
    target_link_libraries(partout-bindings
        PUBLIC Partout::Partout Partout::Models windowsapp runtimeobject ws2_32 iphlpapi
        PRIVATE ole32
    )

    option(PP_TEST_WINRT_RUNTIME "Test the WinRT runtime" OFF)
    if(PP_TEST_WINRT_RUNTIME)
        enable_testing()
        add_subdirectory(tests/c/windows/winrt)
    endif()
elseif(PP_BUILD_WINTUN)
    add_library(partout-wintun-runtime STATIC
        runtimes/windows/wintun/controller.c
    )
    add_library(Partout::WintunRuntime ALIAS partout-wintun-runtime)
    target_include_directories(partout-wintun-runtime PUBLIC
        "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/runtimes/include>"
        "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")
    target_include_directories(partout-wintun-runtime PRIVATE src/c/portable/include "${WINTUN_DIR}")
    target_link_libraries(partout-wintun-runtime PUBLIC Partout::Partout PRIVATE ole32)
    set_target_properties(partout-wintun-runtime PROPERTIES MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
elseif(ANDROID)
    add_library(partout-android-runtime OBJECT
        runtimes/android/native/controller.c
        runtimes/android/native/jni.c
        runtimes/android/native/partout_jni.c
    )
    add_library(Partout::AndroidRuntime ALIAS partout-android-runtime)
    set_target_properties(partout-android-runtime PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        C_VISIBILITY_PRESET hidden
    )
    target_include_directories(partout-android-runtime PRIVATE src)
    target_link_libraries(partout-android-runtime PUBLIC Partout::Partout android log)
elseif(UNIX)
    add_library(partout-posix-runtime STATIC
        runtimes/posix/controller.c
    )
    add_library(Partout::POSIXRuntime ALIAS partout-posix-runtime)
    target_include_directories(partout-posix-runtime
        PUBLIC
            "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/runtimes/include>"
            "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
        PRIVATE src
    )
    target_link_libraries(partout-posix-runtime PUBLIC Partout::Partout)
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
