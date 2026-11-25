# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

execute_process(COMMAND "${LINKER}" /dump /exports "${LIBRARY}"
    OUTPUT_VARIABLE exports RESULT_VARIABLE result ERROR_VARIABLE error)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "Cannot inspect DLL exports: ${error}")
endif()
if(NOT exports MATCHES "partout_version" OR NOT exports MATCHES "VpnChannelRuntime"
   OR NOT exports MATCHES "Tunnel@Partout" OR NOT exports MATCHES "ToString")
    message(FATAL_ERROR "The DLL must export the core, C++ models, and WinRT runtime")
endif()

execute_process(COMMAND "${LINKER}" /dump /imports "${LIBRARY}"
    OUTPUT_VARIABLE imports RESULT_VARIABLE result ERROR_VARIABLE error)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "Cannot inspect core DLL imports: ${error}")
endif()
if(imports MATCHES "winrt_" OR imports MATCHES "partout-winrt" OR imports MATCHES "partout-runtime")
    message(FATAL_ERROR "The core DLL must not import the WinRT runtime")
endif()
