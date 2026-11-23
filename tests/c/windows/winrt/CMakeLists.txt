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
    -P "${CMAKE_CURRENT_SOURCE_DIR}/exports.cmake")
set(winrt_tests log network tun_settings winrt-tunnel-strategy)
set(winrt_test_sources LogTests NetworkMonitorTests TunSettingsTests WinRTTunnelStrategyTests)
foreach(test source IN ZIP_LISTS winrt_tests winrt_test_sources)
    add_executable(partout-${test}-test ${source}.cc)
    target_include_directories(partout-${test}-test PRIVATE "${PROJECT_SOURCE_DIR}/runtimes/windows/winrt")
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

# Exercise private implementations without adding them to the backend DLL exports.
target_sources(partout-network-test PRIVATE
    "${PROJECT_SOURCE_DIR}/runtimes/windows/winrt/NetworkMonitor.cc")
target_sources(partout-tun_settings-test PRIVATE
    "${PROJECT_SOURCE_DIR}/runtimes/windows/winrt/TunSettings.cc")
