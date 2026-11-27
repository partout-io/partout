# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

execute_process(COMMAND "${LINKER}" /dump /exports "${LIBRARY}"
    OUTPUT_VARIABLE exports RESULT_VARIABLE result ERROR_VARIABLE error)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "Cannot inspect DLL exports: ${error}")
endif()
if(NOT exports MATCHES "VpnChannelRuntime"
   OR NOT exports MATCHES "Tunnel@Partout")
    message(FATAL_ERROR "The DLL must export the C++ tunnel and WinRT runtime")
endif()
if(exports MATCHES "[ \t]partout_[A-Za-z0-9_]+[ \r\n]")
    message(FATAL_ERROR "This Windows C++ build must not export the C ABI")
endif()
foreach(method IN ITEMS Initialize ImportProfile WireGuardPublicKey)
    if(NOT exports MATCHES "[?]${method}@Runtime@Partout@@")
        message(FATAL_ERROR "Missing C++ facade export: ${method}")
    endif()
endforeach()
# Match the exported name, not a model mentioned in a runtime method's signature.
if(exports MATCHES "[ \t][?][^ @\r\n]+(@[^ @\r\n]+)?@Models@Partout@@" OR exports MATCHES "validateRfc3339")
    message(FATAL_ERROR "Models must be linked statically, not exported from the DLL")
endif()

execute_process(COMMAND "${LINKER}" /dump /imports "${LIBRARY}"
    OUTPUT_VARIABLE imports RESULT_VARIABLE result ERROR_VARIABLE error)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "Cannot inspect core DLL imports: ${error}")
endif()
if(imports MATCHES "winrt_" OR imports MATCHES "partout-winrt" OR imports MATCHES "partout-runtime")
    message(FATAL_ERROR "The core DLL must not import the WinRT runtime")
endif()
