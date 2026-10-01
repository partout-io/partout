if(TARGET WgGo::wg-go)
    return()
endif()

get_filename_component(_WGGO_PREFIX "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

if(EXISTS "${_WGGO_PREFIX}/lib/wg-go.dll")
    set(_WGGO_LIBRARY_TYPE SHARED)
    set(_WGGO_LOCATION "${_WGGO_PREFIX}/lib/wg-go.dll")
    set(_WGGO_IMPLIB "${_WGGO_PREFIX}/lib/wg-go.lib")
    set(_WGGO_FILES
        "${_WGGO_LOCATION}"
        "${_WGGO_IMPLIB}"
    )
elseif(EXISTS "${_WGGO_PREFIX}/lib/libwg-go.so")
    set(_WGGO_LIBRARY_TYPE SHARED)
    set(_WGGO_LOCATION "${_WGGO_PREFIX}/lib/libwg-go.so")
    set(_WGGO_FILES "${_WGGO_LOCATION}")
elseif(EXISTS "${_WGGO_PREFIX}/lib/libwg-go.dylib")
    set(_WGGO_LIBRARY_TYPE SHARED)
    set(_WGGO_LOCATION "${_WGGO_PREFIX}/lib/libwg-go.dylib")
    set(_WGGO_FILES "${_WGGO_LOCATION}")
elseif(EXISTS "${_WGGO_PREFIX}/lib/libwg-go.a")
    set(_WGGO_LIBRARY_TYPE STATIC)
    set(_WGGO_LOCATION "${_WGGO_PREFIX}/lib/libwg-go.a")
    set(_WGGO_FILES "${_WGGO_LOCATION}")
else()
    message(FATAL_ERROR
        "The WgGo package contains no supported wg-go library under ${_WGGO_PREFIX}/lib"
    )
endif()

add_library(WgGo::wg-go ${_WGGO_LIBRARY_TYPE} IMPORTED)
set_target_properties(WgGo::wg-go PROPERTIES
    IMPORTED_LOCATION "${_WGGO_LOCATION}"
    INTERFACE_INCLUDE_DIRECTORIES "${_WGGO_PREFIX}/include"
)
if(DEFINED _WGGO_IMPLIB)
    set_property(TARGET WgGo::wg-go PROPERTY IMPORTED_IMPLIB "${_WGGO_IMPLIB}")
endif()

foreach(_WGGO_FILE IN LISTS _WGGO_FILES)
    if(NOT EXISTS "${_WGGO_FILE}")
        message(FATAL_ERROR
            "The imported target WgGo::wg-go references missing file: ${_WGGO_FILE}")
    endif()
endforeach()

unset(_WGGO_FILE)
unset(_WGGO_FILES)
unset(_WGGO_IMPLIB)
unset(_WGGO_LIBRARY_TYPE)
unset(_WGGO_LOCATION)
unset(_WGGO_PREFIX)

