# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

option(PP_TEST_CPP_RUNTIME "Test the portable C++ tunnel lifecycle" OFF)
option(PP_TEST_WINRT_RUNTIME "Test the WinRT runtime" OFF)

if(PP_TEST_CPP_RUNTIME AND TARGET Partout::CppRuntime)
    enable_testing()
    add_subdirectory(tests/cpp)
endif()

if(PP_TEST_WINRT_RUNTIME AND TARGET Partout::WinRTRuntime)
    enable_testing()
    add_subdirectory(tests/c/windows/winrt)
endif()
