@echo off
echo ========================================
echo Checking MSVC Installation
echo ========================================
echo.

REM Check if cl.exe (C++ compiler) exists
where cl.exe >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo [OK] C++ Compiler found:
    where cl.exe
) else (
    echo [FAIL] C++ Compiler (cl.exe) NOT found
)

echo.

REM Check if link.exe exists
where link.exe >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo [OK] Linker found:
    where link.exe
) else (
    echo [FAIL] Linker (link.exe) NOT found
)

echo.

REM Check Visual Studio installation using vswhere
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
    echo [OK] Visual Studio Installer found
    echo.
    echo Installed workloads:
    "%VSWHERE%" -latest -property installationPath
    echo.
) else (
    echo [FAIL] Visual Studio Installer NOT found
)

echo.
echo ========================================
echo.
pause
