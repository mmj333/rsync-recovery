@echo off
:: Smart launcher for NTFS permissions fix
:: Detects PowerShell availability and runs appropriate version

echo Checking system capabilities...

:: Check if PowerShell is available
powershell -Command "exit" >nul 2>&1
if %errorlevel% equ 0 (
    echo PowerShell detected - using advanced version
    echo.
    powershell -ExecutionPolicy Bypass -File "%~dp0Fix-NTFSPermissions.ps1" %*
) else (
    echo PowerShell not available - using basic version
    echo.
    call "%~dp0fix_ntfs_permissions.bat"
)