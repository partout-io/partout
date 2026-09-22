# WinRT uses MSVC's C++ runtime and Windows SDK projections. Build this bridge
# separately from Zig's portable C sources; consumers opt in when needed.
option(PP_BUILD_WINRT "Build the WinRT VPN channel bridge" OFF)
if(PP_BUILD_WINRT)
    if(CMAKE_VERSION VERSION_LESS 4.0)
        message(FATAL_ERROR "PP_BUILD_WINRT requires CMake 4.0 or newer")
    endif()
    if(NOT WIN32 OR NOT MSVC)
        message(FATAL_ERROR "PP_BUILD_WINRT requires MSVC and the Windows SDK")
    endif()
    enable_language(CXX)
    add_library(partout-winrt STATIC
        cross/windows/runtime.cc
        cross/windows/socket.cc
        cross/windows/tun.cc
    )
    target_include_directories(partout-winrt PRIVATE
        src src/c/portable/include cross/windows)
    target_compile_features(partout-winrt PRIVATE cxx_std_20)
    target_compile_definitions(partout-winrt PRIVATE
        NOMINMAX WINRT_LEAN_AND_MEAN PARTOUT_WINRT_EXPORTS)
    target_compile_options(partout-winrt PRIVATE /EHsc /permissive- /W4)
    # AppContainer consumers use a CRT without the /RTC helpers.
    set_target_properties(partout-winrt PROPERTIES
        MSVC_RUNTIME_LIBRARY MultiThreadedDLL
        MSVC_RUNTIME_CHECKS ""
    )
    target_link_libraries(partout-winrt PUBLIC windowsapp runtimeobject)
endif()
