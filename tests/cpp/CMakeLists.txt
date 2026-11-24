add_executable(partout-cpp-tunnel-test TunnelTests.cc)
add_executable(partout-cpp-profile-extensions-test ProfileExtensionsTests.cc)
target_link_libraries(partout-cpp-tunnel-test PRIVATE Partout::CppRuntime)
target_link_libraries(partout-cpp-profile-extensions-test PRIVATE Partout::Models)
foreach(test IN ITEMS tunnel profile-extensions)
    set(target partout-cpp-${test}-test)
    if(MSVC)
        target_compile_options(${target} PRIVATE /EHsc /UNDEBUG)
        if(PP_BUILD_LIBRARY AND PP_BUILD_WINRT)
            set_target_properties(${target} PROPERTIES
                MSVC_RUNTIME_LIBRARY MultiThreadedDLL
                MSVC_RUNTIME_CHECKS ""
            )
        endif()
    else()
        target_compile_options(${target} PRIVATE -UNDEBUG)
    endif()
    add_test(NAME partout-cpp-${test} COMMAND ${target})
    if(WIN32 AND PP_BUILD_LIBRARY AND PP_BUILD_WINRT)
        add_custom_command(TARGET ${target} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                $<TARGET_RUNTIME_DLLS:${target}>
                $<TARGET_FILE_DIR:${target}>
            COMMAND_EXPAND_LISTS)
    endif()
endforeach()
