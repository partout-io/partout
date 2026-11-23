cmake_minimum_required(VERSION 3.28)
project(PartoutAndroid LANGUAGES C)

if(NOT ANDROID)
    message(FATAL_ERROR "PartoutAndroid requires the Android NDK toolchain")
endif()

# Keep each Gradle variant and ABI inside its own native build directory.
set(PP_BUILD_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/output" CACHE PATH "Partout output directory")
add_subdirectory("../.." "partout")

add_library(partout-jni SHARED)
target_link_libraries(partout-jni PRIVATE Partout::AndroidRuntime)
