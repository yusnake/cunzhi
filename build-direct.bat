@echo off
setlocal

REM Set PATH with Windows directories ONLY
set "PATH=C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0\;C:\Program Files\nodejs\;C:\Users\YU\.cargo\bin"

REM Navigate to project
cd /d "D:\Cursor-test\cunzhi"

REM Run the build
call npx @tauri-apps/cli build --no-bundle

endlocal
