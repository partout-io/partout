# The legacy NDK toolchain writes its default linker flags directly into
# CMAKE_*_LINKER_FLAGS, which CMake's Swift rules pass through LINK_FLAGS
# without Swift's linker-wrapper syntax.
function(_old_strip_linker_flags variable)
    set(value "${${variable}}")
    foreach(flag IN LISTS ARGN)
        if(flag)
            string(REPLACE "${flag}" "" value "${value}")
        endif()
    endforeach()
    string(STRIP "${value}" value)
    set("${variable}" "${value}" CACHE STRING "Flags used by the linker." FORCE)
    set("${variable}" "${value}" PARENT_SCOPE)
endfunction()

foreach(kind IN ITEMS SHARED MODULE)
    _old_strip_linker_flags("CMAKE_${kind}_LINKER_FLAGS" "${ANDROID_LINKER_FLAGS}")
endforeach()
_old_strip_linker_flags(CMAKE_EXE_LINKER_FLAGS "${ANDROID_LINKER_FLAGS}" "${ANDROID_LINKER_FLAGS_EXE}")

foreach(config IN ITEMS RELEASE RELWITHDEBINFO MINSIZEREL)
    foreach(kind IN ITEMS EXE SHARED MODULE)
        _old_strip_linker_flags("CMAKE_${kind}_LINKER_FLAGS_${config}" "${ANDROID_LINKER_FLAGS_${config}}")
    endforeach()
endforeach()
unset(config)
unset(kind)
