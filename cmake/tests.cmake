# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

option(PP_TEST_CPP_RUNTIME "Test the portable C++ tunnel lifecycle" OFF)
option(PP_TEST_WINRT_RUNTIME "Test the WinRT runtime" OFF)

if(PP_TEST_CPP_RUNTIME AND TARGET partout-cpp-runtime)
    enable_testing()
    add_subdirectory(runtimes/tests/cpp)
endif()

if(PP_TEST_WINRT_RUNTIME AND TARGET partout-winrt-runtime)
    enable_testing()
    add_subdirectory(runtimes/tests/windows/winrt)
endif()
