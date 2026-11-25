# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

cmake_minimum_required(VERSION 3.28)
project(PartoutSDKConsumer LANGUAGES CXX)

find_package(Partout CONFIG REQUIRED)

add_executable(partout-sdk-consumer SDKConsumer.cc)
target_link_libraries(partout-sdk-consumer PRIVATE Partout::Partout)
if(WIN32)
    target_compile_options(partout-sdk-consumer PRIVATE /EHsc)
    add_custom_command(TARGET partout-sdk-consumer POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_RUNTIME_DLLS:partout-sdk-consumer>
            $<TARGET_FILE_DIR:partout-sdk-consumer>
        COMMAND_EXPAND_LISTS)
endif()

enable_testing()
add_test(NAME partout-sdk-consumer COMMAND partout-sdk-consumer)
