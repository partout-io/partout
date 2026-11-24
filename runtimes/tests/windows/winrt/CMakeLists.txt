# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

add_executable(partout-runtime-link-test RuntimeLinkTests.cc)
target_compile_options(partout-runtime-link-test PRIVATE /EHsc)
set_target_properties(partout-runtime-link-test PROPERTIES
    MSVC_RUNTIME_LIBRARY MultiThreadedDLL
    MSVC_RUNTIME_CHECKS ""
)
target_link_libraries(partout-runtime-link-test PRIVATE Partout::WinRTRuntime)
add_custom_command(TARGET partout-runtime-link-test POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_RUNTIME_DLLS:partout-runtime-link-test>
        $<TARGET_FILE_DIR:partout-runtime-link-test>
    COMMAND_EXPAND_LISTS)
add_test(NAME partout-runtime-link COMMAND partout-runtime-link-test)
add_test(NAME partout-exports COMMAND ${CMAKE_COMMAND}
    "-DLINKER=${CMAKE_LINKER}"
    "-DLIBRARY=$<TARGET_FILE:Partout::Core>"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/exports.cmake")
set(winrt_tests log network tun_settings winrt-tunnel-strategy runtime-loop)
set(winrt_test_sources LogTests NetworkMonitorTests TunSettingsTests WinRTTunnelStrategyTests RuntimeLoopTests)
foreach(test source IN ZIP_LISTS winrt_tests winrt_test_sources)
    add_executable(partout-${test}-test ${source}.cc)
    target_include_directories(partout-${test}-test PRIVATE
        "${PROJECT_SOURCE_DIR}/runtimes/windows/winrt"
        "${PROJECT_SOURCE_DIR}/src/c/portable/include")
    target_compile_options(partout-${test}-test PRIVATE /EHsc /UNDEBUG)
    set_target_properties(partout-${test}-test PROPERTIES
        MSVC_RUNTIME_LIBRARY MultiThreadedDLL
        MSVC_RUNTIME_CHECKS ""
    )
    target_link_libraries(partout-${test}-test PRIVATE Partout::WinRTRuntime)
    add_custom_command(TARGET partout-${test}-test POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_RUNTIME_DLLS:partout-${test}-test>
            $<TARGET_FILE_DIR:partout-${test}-test>
        COMMAND_EXPAND_LISTS)
    add_test(NAME partout-${test} COMMAND partout-${test}-test)
endforeach()
