set(WINTUN_DIR ${PP_BUILD_OUTPUT}/wintun)
set(WINTUN_URL "https://www.wintun.net/builds/wintun-${WINTUN_VERSION}.zip")
FetchContent_Declare(
    wintun
    URL ${WINTUN_URL}
    SOURCE_DIR ${CMAKE_BINARY_DIR}/wintun-src
)
FetchContent_MakeAvailable(wintun)
file(COPY ${wintun_SOURCE_DIR}/include/wintun.h DESTINATION ${WINTUN_DIR})
file(COPY ${wintun_SOURCE_DIR}/bin/${ARCH_NAME}/wintun.dll DESTINATION ${WINTUN_DIR})
