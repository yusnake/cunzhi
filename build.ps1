# Tauri Build Script - Using npx
Write-Host "Starting Tauri build..." -ForegroundColor Cyan

# Change to project directory
Set-Location -Path "D:\Cursor-test\cunzhi"
Write-Host "Current directory: $PWD" -ForegroundColor Green

# Check frontend build
Write-Host "Checking frontend build..." -ForegroundColor Yellow
if (!(Test-Path ".\dist\index.html")) {
    Write-Host "Building frontend..." -ForegroundColor Yellow
    pnpm build
}
Write-Host "Frontend ready" -ForegroundColor Green

# Build Tauri using npx (uses npm-installed @tauri-apps/cli)
Write-Host "Building Tauri application..." -ForegroundColor Yellow
Write-Host "This will take 5-15 minutes (first build)" -ForegroundColor Gray

npx @tauri-apps/cli build --no-bundle

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Build successful!" -ForegroundColor Green
    Write-Host ""

    if (Test-Path ".\target\release\等一下.exe") {
        $size = (Get-Item ".\target\release\等一下.exe").Length / 1MB
        Write-Host "Generated: 等一下.exe ($([math]::Round($size, 2)) MB)" -ForegroundColor Green
    }

    if (Test-Path ".\target\release\寸止.exe") {
        $size = (Get-Item ".\target\release\寸止.exe").Length / 1MB
        Write-Host "Generated: 寸止.exe ($([math]::Round($size, 2)) MB)" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Location: D:\Cursor-test\cunzhi\target\release\" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "Build failed!" -ForegroundColor Red
    exit 1
}
