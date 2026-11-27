# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

option(PP_TEST_CPP_RUNTIME "Test the portable C++ tunnel lifecycle" OFF)
option(PP_TEST_WINRT_RUNTIME "Test the WinRT runtime" OFF)
option(PP_TEST_WINTUN_RUNTIME "Test Wintun settings with fake Windows APIs" OFF)

if(PP_TEST_CPP_RUNTIME AND TARGET partout-cpp-runtime)
    enable_testing()
    add_subdirectory(runtimes/tests/cpp)
endif()

if(PP_TEST_WINRT_RUNTIME AND TARGET partout-winrt-runtime)
    enable_testing()
    add_subdirectory(runtimes/tests/windows/winrt)
endif()

if(PP_TEST_WINTUN_RUNTIME AND TARGET partout-wintun-runtime)
    enable_testing()
    add_subdirectory(runtimes/tests/windows/wintun)
endif()
