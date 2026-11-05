# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

if(TARGET partout-windows)
    target_link_libraries(partout-windows PUBLIC Partout::Partout)
    option(PP_TEST_RUNTIME_LINK "Test the separately linked Windows runtime" OFF)
    if(PP_TEST_RUNTIME_LINK)
        enable_testing()
        add_executable(partout-runtime-link-test tests/c/windows/runtime_link.cc)
        target_compile_options(partout-runtime-link-test PRIVATE /EHsc)
        target_link_libraries(partout-runtime-link-test PRIVATE msvcrt Partout::WindowsRuntime)
        add_custom_command(TARGET partout-runtime-link-test POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "$<TARGET_FILE:Partout::Partout>" "$<TARGET_FILE:partout-windows-backend>"
                "$<TARGET_FILE_DIR:partout-runtime-link-test>")
        add_test(NAME partout-runtime-link COMMAND partout-runtime-link-test)
    endif()
endif()
# Native integration layers consume the public core ABI.
if(ANDROID)
    add_library(partout-android-runtime OBJECT
        cross/android/native/controller.c
        cross/android/native/jni.c
        cross/android/native/partout_jni.c)
    add_library(Partout::AndroidRuntime ALIAS partout-android-runtime)
    set_target_properties(partout-android-runtime PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        C_VISIBILITY_PRESET hidden)
    target_include_directories(partout-android-runtime PRIVATE src)
    target_link_libraries(partout-android-runtime PUBLIC Partout::Partout android log)
elseif(UNIX)
    add_library(partout-posix-runtime STATIC cross/posix/controller.c cross/posix/tun.c)
    add_library(Partout::PosixRuntime ALIAS partout-posix-runtime)
    target_include_directories(partout-posix-runtime PUBLIC cross/posix/include PRIVATE src)
    target_link_libraries(partout-posix-runtime PUBLIC Partout::Partout)
endif()
