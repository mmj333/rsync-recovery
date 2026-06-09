@echo off
:: Fix NTFS Permissions Script
:: Version: 1.1
:: Purpose: Reset permissions on recovered drives for customer access
:: Run as Administrator

setlocal enabledelayedexpansion

echo ========================================
echo   NTFS Permissions Fix Tool
echo   For Data Recovery Drives
echo ========================================
echo.
echo This tool will reset permissions on a drive to allow full access.
echo You MUST run this as Administrator!
echo.

:: Check for admin rights
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: This script requires Administrator privileges!
    echo Right-click and select "Run as administrator"
    pause
    exit /b 1
)

:: Get drive letter
set /p "DRIVE=Enter drive letter to fix (e.g., E): "
set "DRIVE=%DRIVE%:"

:: Validate drive exists
if not exist "%DRIVE%\" (
    echo ERROR: Drive %DRIVE% does not exist!
    pause
    exit /b 1
)

echo.
echo Selected drive: %DRIVE%
echo.

:: Check if drive is marked dirty
echo Checking drive status...
fsutil dirty query %DRIVE% | find "is Dirty" >nul
if %errorlevel% equ 0 (
    echo.
    echo WARNING: Drive is marked as DIRTY and needs checking!
    set "DEFAULT_CHKDSK=Y"
) else (
    echo Drive is not marked dirty.
    set "DEFAULT_CHKDSK=Y"
)

echo.
echo It's recommended to run CHKDSK before fixing permissions.
echo This will check and repair any filesystem errors.
echo.
set /p "RUN_CHKDSK=Run CHKDSK first? [Y/n] (default=%DEFAULT_CHKDSK%): "
if "%RUN_CHKDSK%"=="" set "RUN_CHKDSK=%DEFAULT_CHKDSK%"

if /i "%RUN_CHKDSK%"=="Y" (
    echo.
    echo Running CHKDSK on %DRIVE% (this may take a while)...
    echo.
    chkdsk %DRIVE% /f /x
    if %errorlevel% neq 0 (
        echo.
        echo WARNING: CHKDSK reported issues or was cancelled.
        set /p "CONTINUE=Continue with permissions fix anyway? (Y/N): "
        if /i not "!CONTINUE!"=="Y" (
            echo Operation cancelled.
            pause
            exit /b 1
        )
    ) else (
        echo.
        echo CHKDSK completed successfully.
    )
)

echo.
echo WARNING: This will:
echo - Take ownership of all files and folders
echo - Grant full permissions to Everyone
echo - Remove any access restrictions
echo.
set /p "CONFIRM=Are you sure you want to continue? (Y/N): "
if /i not "%CONFIRM%"=="Y" (
    echo Operation cancelled.
    pause
    exit /b 0
)

echo.
echo Starting permissions fix...
echo This may take a while for large drives.
echo.

:: Take ownership of everything (first as admin, then we'll set to Everyone)
echo Step 1/4: Taking ownership of all files...
takeown /f "%DRIVE%\" /r /d y >nul 2>&1
if %errorlevel% neq 0 (
    echo WARNING: Some ownership changes may have failed, continuing...
)

:: Set owner to Administrators group (S-1-5-32-544 is universal across Windows)
echo Step 2/4: Setting owner to Administrators group...
icacls "%DRIVE%\" /setowner "Administrators" /t /c /q >nul 2>&1

:: Reset permissions using icacls
echo Step 3/4: Resetting permissions...
:: Grant full control to Everyone
icacls "%DRIVE%\*" /grant Everyone:F /t /c /q >nul 2>&1

:: Also grant to common groups
icacls "%DRIVE%\*" /grant "Authenticated Users":F /t /c /q >nul 2>&1
icacls "%DRIVE%\*" /grant "Users":F /t /c /q >nul 2>&1

:: Reset inheritance
echo Step 4/4: Enabling permission inheritance...
icacls "%DRIVE%\" /inheritance:e /t /c /q >nul 2>&1

echo.
echo ========================================
echo   Permissions fix complete!
echo ========================================
echo.
echo The drive should now be fully accessible.
echo.
echo If you still have issues with specific folders, try:
echo 1. Right-click the problem folder
echo 2. Properties → Security → Advanced
echo 3. Click "Change" next to Owner
echo 4. Type "Everyone" and click OK
echo 5. Check "Replace owner on subcontainers"
echo.
pause