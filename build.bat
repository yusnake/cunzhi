@echo off
echo Starting Tauri build...
cd /d D:\Cursor-test\cunzhi
cargo tauri build --bundles none
echo Build completed!
pause
