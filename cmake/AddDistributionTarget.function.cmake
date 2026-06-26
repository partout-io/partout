include_guard(GLOBAL)

function(partout_add_distribution_target target_name)
    set(options ALL)
    set(one_value_args OUTPUT_DIR DIST_DIR SWIFT_ROOT SWIFT_VERSION)
    cmake_parse_arguments(PARTOUT_DIST "${options}" "${one_value_args}" "" ${ARGN})

    if(NOT PARTOUT_DIST_OUTPUT_DIR)
        if(DEFINED PP_BUILD_OUTPUT)
            set(PARTOUT_DIST_OUTPUT_DIR "${PP_BUILD_OUTPUT}")
        else()
            message(FATAL_ERROR "partout_add_distribution_target requires OUTPUT_DIR")
        endif()
    endif()
    if(NOT PARTOUT_DIST_DIST_DIR)
        message(FATAL_ERROR "partout_add_distribution_target requires DIST_DIR")
    endif()
    if(NOT TARGET partout)
        message(FATAL_ERROR "partout_add_distribution_target requires the partout target")
    endif()

    if(PARTOUT_DIST_ALL)
        set(all_arg ALL)
    else()
        set(all_arg)
    endif()

    set(partout_distribution_args
        "-DSWIFT_ROOT=${PARTOUT_DIST_SWIFT_ROOT}"
        "-DSWIFT_VERSION=${PARTOUT_DIST_SWIFT_VERSION}"
        "-DPARTOUT_OUTPUT_DIR=${PARTOUT_DIST_OUTPUT_DIR}"
        "-DPARTOUT_DIST_DIR=${PARTOUT_DIST_DIST_DIR}"
    )
    if(PARTOUT_DIST_SWIFT_ROOT)
        list(APPEND partout_distribution_args "-DSWIFT_ROOT=${PARTOUT_DIST_SWIFT_ROOT}")
    elseif(DEFINED SWIFT_ROOT)
        list(APPEND partout_distribution_args "-DSWIFT_ROOT=${SWIFT_ROOT}")
    endif()
    if(PARTOUT_DIST_SWIFT_VERSION)
        list(APPEND partout_distribution_args "-DSWIFT_VERSION=${PARTOUT_DIST_SWIFT_VERSION}")
    elseif(DEFINED SWIFT_VERSION)
        list(APPEND partout_distribution_args "-DSWIFT_VERSION=${SWIFT_VERSION}")
    endif()

    add_custom_target(${target_name} ${all_arg}
        COMMAND ${CMAKE_COMMAND}
            ${partout_distribution_args}
            -P "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/distribute.script.cmake"
        VERBATIM
    )
    add_dependencies(${target_name} partout)
endfunction()
