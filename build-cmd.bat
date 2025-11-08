@echo off
echo ===================================
echo Starting Tauri Build in CMD
echo ===================================
echo.

REM Change to project directory
cd /d D:\Cursor-test\cunzhi
echo [1/3] Current directory: %CD%
echo.

REM Set PATH with Windows system paths first to avoid Git Bash link conflict
echo [2/3] Configuring environment...
set "PATH=C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files\nodejs;C:\Users\YU\.cargo\bin;%PATH%"
echo PATH configured (Windows system32 first)
echo.

REM Check if frontend is built
echo [3/3] Building application...
if not exist "dist\index.html" (
    echo Frontend not built, building...
    call pnpm build
    if errorlevel 1 (
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

if errorlevel 1 (
    echo.
    echo ===================================
    echo Build FAILED!
    echo ===================================
    echo.
    pause
    exit /b 1
) else (
    echo.
    echo ===================================
    echo Build SUCCESSFUL!
    echo ===================================
    echo.

    if exist "target\release\等一下.exe" (
        for %%A in ("target\release\等一下.exe") do (
            set /a size=%%~zA/1024/1024
            echo Generated: 等一下.exe (!size! MB^)
        )
    )

    if exist "target\release\寸止.exe" (
        for %%A in ("target\release\寸止.exe") do (
            set /a size=%%~zA/1024/1024
            echo Generated: 寸止.exe (!size! MB^)
        )
    )

    echo.
    echo Location: D:\Cursor-test\cunzhi\target\release\
    echo.
    pause
)
