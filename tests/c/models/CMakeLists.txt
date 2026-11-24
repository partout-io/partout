cmake_minimum_required(VERSION 3.28)
project(PartoutModelTests LANGUAGES CXX)

# Exercise the installed SDK through its exported model target.
find_package(Partout CONFIG REQUIRED)
add_executable(partout-models-test ModelsTests.cc)
target_link_libraries(partout-models-test PRIVATE Partout::Models)
if(WIN32)
    add_custom_command(TARGET partout-models-test POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_RUNTIME_DLLS:partout-models-test>
            $<TARGET_FILE_DIR:partout-models-test>
        COMMAND_EXPAND_LISTS)
endif()
if(MSVC)
    target_compile_options(partout-models-test PRIVATE /UNDEBUG)
else()
    target_compile_options(partout-models-test PRIVATE -UNDEBUG)
endif()
enable_testing()
add_test(NAME partout-models COMMAND partout-models-test)
