# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

if(NOT PP_BUILD_LIBRARY)
    return()
endif()

# Native integration layers consume the public core ABI.
if(TARGET partout-winrt-backend)
    add_library(partout-bindings STATIC
        cross/windows/winrt/src/tunnel.cc
        cross/windows/winrt/src/runtime.cc
        cross/windows/winrt/src/platform.cc
    )
    add_library(Partout::WinRTRuntime ALIAS partout-bindings)
    target_include_directories(partout-bindings
        PUBLIC
            "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/cross/windows/winrt/include>"
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

    option(PP_TEST_RUNTIME_LINK "Test the separately linked Windows runtime" OFF)
    if(PP_TEST_RUNTIME_LINK)
        enable_testing()
        add_executable(partout-runtime-link-test tests/c/windows/runtime_link.cc)
        target_compile_options(partout-runtime-link-test PRIVATE /EHsc)
        set_target_properties(partout-runtime-link-test PROPERTIES
            MSVC_RUNTIME_LIBRARY MultiThreadedDLL
            MSVC_RUNTIME_CHECKS ""
        )
        target_link_libraries(partout-runtime-link-test PRIVATE Partout::WinRTRuntime)
        add_custom_command(TARGET partout-runtime-link-test POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "$<TARGET_FILE:Partout::Partout>" "$<TARGET_FILE:partout-winrt-backend>"
                "$<TARGET_FILE_DIR:partout-runtime-link-test>"
        )
        foreach(runtime IN LISTS PARTOUT_RUNTIME_LIBRARIES)
            add_custom_command(TARGET partout-runtime-link-test POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "$<TARGET_FILE:${runtime}>"
                    "$<TARGET_FILE_DIR:partout-runtime-link-test>")
        endforeach()
        add_test(NAME partout-runtime-link COMMAND partout-runtime-link-test)
        add_test(NAME partout-exports COMMAND ${CMAKE_COMMAND}
            "-DLINKER=${CMAKE_LINKER}"
            "-DLIBRARY=$<TARGET_FILE:Partout::Partout>"
            "-DBACKEND=$<TARGET_FILE:partout-winrt-backend>"
            -P "${CMAKE_CURRENT_SOURCE_DIR}/tests/c/windows/exports.cmake")
        foreach(test IN ITEMS tunnel tunnel_profile)
            add_executable(partout-${test}-test tests/c/windows/${test}.cc)
            target_include_directories(partout-${test}-test PRIVATE cross/windows/winrt/src)
            target_compile_options(partout-${test}-test PRIVATE /EHsc /UNDEBUG)
            set_target_properties(partout-${test}-test PROPERTIES
                MSVC_RUNTIME_LIBRARY MultiThreadedDLL
                MSVC_RUNTIME_CHECKS ""
            )
            target_link_libraries(partout-${test}-test PRIVATE Partout::WinRTRuntime)
            add_test(NAME partout-${test} COMMAND partout-${test}-test)
        endforeach()
    endif()
elseif(PP_BUILD_WINTUN)
    add_library(partout-wintun-runtime STATIC cross/windows/wintun/controller.c)
    add_library(Partout::WintunRuntime ALIAS partout-wintun-runtime)
    target_include_directories(partout-wintun-runtime PUBLIC
        "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/cross/windows/wintun/include>"
        "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")
    target_include_directories(partout-wintun-runtime PRIVATE src/c/portable/include "${WINTUN_DIR}")
    target_link_libraries(partout-wintun-runtime PUBLIC Partout::Partout PRIVATE ole32)
    set_target_properties(partout-wintun-runtime PROPERTIES MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
elseif(ANDROID)
    add_library(partout-android-runtime OBJECT
        cross/android/native/controller.c
        cross/android/native/jni.c
        cross/android/native/partout_jni.c
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
        cross/posix/controller.c
    )
    add_library(Partout::PosixRuntime ALIAS partout-posix-runtime)
    target_include_directories(partout-posix-runtime
        PUBLIC
            "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/cross/posix/include>"
            "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
        PRIVATE src
    )
    target_link_libraries(partout-posix-runtime PUBLIC Partout::Partout)
endif()
