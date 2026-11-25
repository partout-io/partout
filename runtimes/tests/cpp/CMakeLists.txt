cmake_minimum_required(VERSION 3.28)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(PartoutCppTests LANGUAGES CXX)
    find_package(Partout CONFIG REQUIRED)
    enable_testing()
endif()

add_executable(partout-cpp-tunnel-test TunnelTests.cc)
add_executable(partout-cpp-profile-extensions-test ProfileExtensionsTests.cc)
target_link_libraries(partout-cpp-tunnel-test PRIVATE Partout::Partout)
target_link_libraries(partout-cpp-profile-extensions-test PRIVATE Partout::Partout)
add_executable(partout-cpp-models-test ModelsTests.cc)
target_link_libraries(partout-cpp-models-test PRIVATE Partout::Partout)
foreach(test IN ITEMS tunnel profile-extensions models)
    set(target partout-cpp-${test}-test)
    if(MSVC)
        target_compile_options(${target} PRIVATE /EHsc /UNDEBUG)
        set_target_properties(${target} PROPERTIES
            MSVC_RUNTIME_LIBRARY MultiThreadedDLL
            MSVC_RUNTIME_CHECKS ""
        )
    else()
        target_compile_options(${target} PRIVATE -UNDEBUG)
    endif()
    if(WIN32)
        add_custom_command(TARGET ${target} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                $<TARGET_RUNTIME_DLLS:${target}> $<TARGET_FILE_DIR:${target}>
            COMMAND_EXPAND_LISTS)
    endif()
    add_test(NAME partout-cpp-${test} COMMAND ${target})
endforeach()
