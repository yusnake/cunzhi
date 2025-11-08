@echo off
echo ========================================
echo Building Tauri App with MSVC
echo ========================================
echo.

REM Find Visual Studio installation path
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath`) do (
    set "VS_PATH=%%i"
)

if not defined VS_PATH (
    echo ERROR: Visual Studio not found!
    pause
    exit /b 1
)

echo Found Visual Studio at: %VS_PATH%
echo.

REM Setup MSVC environment
call "%VS_PATH%\VC\Auxiliary\Build\vcvars64.bat"

if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to setup MSVC environment
    pause
    exit /b 1
)

echo MSVC environment configured
echo.

REM Navigate to project directory
cd /d "D:\Cursor-test\cunzhi"

REM Check if frontend is built
if not exist "dist\index.html" (
    echo Building frontend...
    call pnpm build
    if %ERRORLEVEL% NEQ 0 (
        echo ERROR: Frontend build failed!
        pause
        exit /b 1
    )
)

echo Frontend ready
echo.

REM Build Tauri application
echo Starting Rust compilation...
echo This will take 5-15 minutes (first build)
echo.

call npx @tauri-apps/cli build --no-bundle

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ===================================
    echo Build SUCCESSFUL!
    echo ===================================
    echo.

    if exist "target\release\等一下.exe" (
        for %%A in ("target\release\等一下.exe") do (
            set /a size=%%~zA/1024/1024
            echo Generated: 等一下.exe (!size! MB)
        )
    )

    if exist "target\release\寸止.exe" (
        for %%A in ("target\release\寸止.exe") do (
            set /a size=%%~zA/1024/1024
            echo Generated: 寸止.exe (!size! MB)
        )
    )

    echo.
    echo Location: D:\Cursor-test\cunzhi\target\release\
    echo.
) else (
    echo.
    echo ===================================
    echo Build FAILED!
    echo ===================================
    echo.
)

pause
