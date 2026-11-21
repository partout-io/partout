# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

add_executable(partout-wintun-settings-test NetworkSettingsTests.cc)
target_include_directories(partout-wintun-settings-test PRIVATE
    "${PROJECT_SOURCE_DIR}/runtimes/windows/wintun")
target_link_libraries(partout-wintun-settings-test PRIVATE partout-wintun-runtime Partout::Partout)
set_target_properties(partout-wintun-settings-test PROPERTIES
    MSVC_RUNTIME_LIBRARY MultiThreadedDLL
    MSVC_RUNTIME_CHECKS "")
add_custom_command(TARGET partout-wintun-settings-test POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_RUNTIME_DLLS:partout-wintun-settings-test>
        $<TARGET_FILE_DIR:partout-wintun-settings-test>
    COMMAND_EXPAND_LISTS)
add_test(NAME partout-wintun-settings COMMAND partout-wintun-settings-test)
