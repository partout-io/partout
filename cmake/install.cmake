include(GNUInstallDirs)

set(partout_install_sdk_export)
set(partout_install_sdk_archive)
if(partout_install_sdk)
    set(partout_install_sdk_export EXPORT PartoutTargets)
    set(partout_install_sdk_archive ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
endif()

if(WIN32)
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_BINDIR}")
else()
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}")
endif()

if(PP_BUILD_LIBRARY)
    set_target_properties(partout PROPERTIES EXPORT_NAME Partout)
    install(TARGETS partout ${partout_install_sdk_export}
        LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
        ${partout_install_sdk_archive}
    )
endif()
if(PARTOUT_RUNTIME_LIBRARIES)
    install(IMPORTED_RUNTIME_ARTIFACTS ${PARTOUT_RUNTIME_LIBRARIES}
        LIBRARY DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        RUNTIME DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
    )
endif()

if(WIN32 AND PP_BUILD_LIBRARY)
    # MSVC writes the PDB beside the final DLL.
    install(FILES "$<TARGET_PDB_FILE:partout>"
        DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        CONFIGURATIONS Debug RelWithDebInfo
        OPTIONAL
    )
endif()

if(PP_BUILD_WINTUN AND PP_BUILD_LIBRARY)
    install(FILES "${WINTUN_DIR}/wintun.dll" DESTINATION "${CMAKE_INSTALL_BINDIR}")
endif()

# App installations need shared runtimes, but not the development SDK.
if(NOT partout_install_sdk)
    return()
endif()

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/src/partout.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
)
if(TARGET partout-winrt-runtime)
    install(DIRECTORY runtimes/windows/winrt/include/partout
        DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
        FILES_MATCHING PATTERN "*.h")
endif()

set_target_properties(partout-headers PROPERTIES EXPORT_NAME Headers)
install(TARGETS partout-headers EXPORT PartoutTargets)
set(PARTOUT_PACKAGE_CPP_RUNTIME OFF)
if(TARGET partout-cpp-runtime)
    set(PARTOUT_PACKAGE_CPP_RUNTIME ON)
    set_target_properties(partout-models PROPERTIES EXPORT_NAME Models)
    install(TARGETS partout-models EXPORT PartoutTargets
        ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
    install(DIRECTORY "${PARTOUT_CPP_INCLUDE}/partout" DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
        FILES_MATCHING PATTERN "*.h")
endif()

include(CMakePackageConfigHelpers)
set(partout_package_dir "${CMAKE_INSTALL_LIBDIR}/cmake/partout")
configure_package_config_file("${CMAKE_CURRENT_LIST_DIR}/PartoutConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/PartoutConfig.cmake"
    INSTALL_DESTINATION "${partout_package_dir}")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/PartoutConfig.cmake"
    DESTINATION "${partout_package_dir}")
install(EXPORT PartoutTargets NAMESPACE Partout::
    DESTINATION "${partout_package_dir}")
