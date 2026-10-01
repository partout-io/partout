@if "%PROCESSOR_ARCHITECTURE%"=="ARM64" set TARGET=aarch64-w64-mingw32
@if "%PROCESSOR_ARCHITECTURE%"=="AMD64" set TARGET=x86_64-w64-mingw32
@if not defined TARGET (
    echo Unsupported GOARCH=%GOARCH%
    exit /b 1
)
@if not defined LLVM_MINGW_ROOT (
    echo LLVM_MINGW_ROOT is required
    exit /b 1
)
@set CC=%LLVM_MINGW_ROOT%\bin\%TARGET%-clang.exe
@set CXX=%LLVM_MINGW_ROOT%\bin\%TARGET%-clang++.exe
@if not exist "%CC%" (
    echo Missing clang: %CC%
    exit /b 1
)
nmake /f Makefile.windows DESTDIR=%~1 TARGET=%TARGET% CC=%CC% CXX=%CXX%
