include(GNUInstallDirs)

if(WIN32)
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_BINDIR}")
else()
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}")
endif()

function(partout_install_runtime_file file)
    install(FILES "${file}"
        DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        OPTIONAL
    )
endfunction()

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/src/partout.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
)
if(TARGET partout-windows)
    install(TARGETS partout-windows partout-windows-backend
        ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/cross/windows/include/partout_winrt.h"
        DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
    )
endif()

set(PARTOUT_INSTALL_RUNTIME_TARGETS ${PARTOUT_RUNTIME_LIBRARIES})
if(PP_BUILD_LIBRARY)
    list(PREPEND PARTOUT_INSTALL_RUNTIME_TARGETS Partout::Partout)
endif()
if(PARTOUT_INSTALL_RUNTIME_TARGETS)
    install(IMPORTED_RUNTIME_ARTIFACTS ${PARTOUT_INSTALL_RUNTIME_TARGETS}
        LIBRARY DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        RUNTIME DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
    )
endif()

if(WIN32 AND PP_BUILD_LIBRARY)
    # Zig installs the PDB beside its DLL; preserve it in the final package so
    # native debuggers can find the matching symbols without extra search paths.
    install(FILES "${PP_BUILD_OUTPUT}/partout/bin/partout.pdb"
        DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        CONFIGURATIONS Debug RelWithDebInfo
        OPTIONAL
    )
endif()

if(TARGET partout-posix-runtime)
    install(TARGETS partout-posix-runtime ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
    install(FILES cross/posix/include/partout_posix.h DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
endif()
