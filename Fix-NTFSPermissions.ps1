# Fix NTFS Permissions PowerShell Script
# Version: 1.1
# Purpose: Reset permissions on recovered drives for customer access
# Run as Administrator

#Requires -RunAsAdministrator

param(
    [string]$DriveLetter = "",
    [switch]$Silent = $false,
    [switch]$QuickMode = $false,
    [switch]$SkipChkdsk = $false
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   NTFS Permissions Fix Tool" -ForegroundColor Cyan
Write-Host "   For Data Recovery Drives" -ForegroundColor Cyan  
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get drive letter if not provided
if (-not $DriveLetter) {
    $DriveLetter = Read-Host "Enter drive letter to fix (e.g., E)"
}

# Ensure proper format
$DriveLetter = $DriveLetter.TrimEnd(':') + ':'
$DrivePath = $DriveLetter + '\'

# Validate drive exists
if (-not (Test-Path $DrivePath)) {
    Write-Host "ERROR: Drive $DriveLetter does not exist!" -ForegroundColor Red
    if (-not $Silent) { pause }
    exit 1
}

Write-Host "Selected drive: $DriveLetter" -ForegroundColor Yellow
Write-Host ""

# Show drive info
try {
    $volume = Get-Volume -DriveLetter $DriveLetter.TrimEnd(':')
    Write-Host "Drive Label: $($volume.FileSystemLabel)"
    Write-Host "File System: $($volume.FileSystem)"
    Write-Host "Size: $([math]::Round($volume.Size / 1GB, 2)) GB"
    Write-Host ""
} catch {
    Write-Host "Could not get drive information" -ForegroundColor Yellow
}

# Check if we should run chkdsk
if (-not $SkipChkdsk) {
    Write-Host "Checking drive status..." -ForegroundColor Cyan
    
    # Check if drive is dirty
    $dirtyBit = & fsutil dirty query $DriveLetter 2>&1
    $isDirty = $dirtyBit -match "is Dirty"
    
    if ($isDirty) {
        Write-Host "WARNING: Drive is marked as DIRTY and needs checking!" -ForegroundColor Red
        $defaultChkdsk = "Y"
    } else {
        Write-Host "Drive is not marked dirty." -ForegroundColor Green
        $defaultChkdsk = "Y"  # Still recommend it
    }
    
    if (-not $Silent) {
        Write-Host ""
        Write-Host "It's recommended to run CHKDSK before fixing permissions." -ForegroundColor Yellow
        Write-Host "This will check and repair any filesystem errors." -ForegroundColor Yellow
        Write-Host ""
        
        $runChkdsk = Read-Host "Run CHKDSK first? [Y/n] (default=$defaultChkdsk)"
        if ([string]::IsNullOrEmpty($runChkdsk)) { $runChkdsk = $defaultChkdsk }
        
        if ($runChkdsk -eq 'Y') {
            Write-Host ""
            Write-Host "Running CHKDSK on ${DriveLetter} (this may take a while)..." -ForegroundColor Yellow
            Write-Host ""
            
            # Run chkdsk
            $chkdskResult = & chkdsk $DriveLetter /f /x 2>&1
            $exitCode = $LASTEXITCODE
            
            # Display results
            $chkdskResult | Write-Host
            
            if ($exitCode -ne 0) {
                Write-Host ""
                Write-Host "WARNING: CHKDSK reported issues or was cancelled." -ForegroundColor Red
                $continue = Read-Host "Continue with permissions fix anyway? (Y/N)"
                if ($continue -ne 'Y') {
                    Write-Host "Operation cancelled." -ForegroundColor Yellow
                    pause
                    exit 1
                }
            } else {
                Write-Host ""
                Write-Host "CHKDSK completed successfully." -ForegroundColor Green
            }
        }
    }
}

if (-not $Silent) {
    Write-Host ""
    Write-Host "WARNING: This will:" -ForegroundColor Yellow
    Write-Host "- Take ownership of all files and folders"
    Write-Host "- Grant full permissions to Everyone" 
    Write-Host "- Remove any access restrictions"
    Write-Host ""
    
    $confirm = Read-Host "Are you sure you want to continue? (Y/N)"
    if ($confirm -ne 'Y') {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        pause
        exit 0
    }
}

Write-Host ""
Write-Host "Starting permissions fix..." -ForegroundColor Green
Write-Host "This may take a while for large drives." -ForegroundColor Yellow
Write-Host ""

# Function to show progress
$script:fileCount = 0
$script:errorCount = 0

function Show-Progress {
    param($Activity, $Status)
    if (-not $Silent) {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete -1
    }
}

# Step 1: Take ownership
Write-Host "Step 1/4: Taking ownership of all files..." -ForegroundColor Cyan
Show-Progress "Taking Ownership" "Processing..."

if ($QuickMode) {
    # Quick mode - just do root
    & takeown /f $DrivePath /d y 2>&1 | Out-Null
} else {
    # Full recursive mode
    & takeown /f $DrivePath /r /d y 2>&1 | Out-Null
}

# Step 2: Set owner to Administrators group
Write-Host "Step 2/4: Setting owner to Administrators group..." -ForegroundColor Cyan
Show-Progress "Setting Owner" "Changing owner to Administrators..."

# Use icacls to set owner to Administrators (S-1-5-32-544)
# This group exists on all Windows systems with the same SID
if ($QuickMode) {
    & icacls $DrivePath /setowner "Administrators" /c /q 2>&1 | Out-Null
} else {
    & icacls $DrivePath /setowner "Administrators" /t /c /q 2>&1 | Out-Null
}

# Step 3: Reset permissions
Write-Host "Step 3/4: Resetting permissions..." -ForegroundColor Cyan
Show-Progress "Resetting Permissions" "Granting access to Everyone..."

# Build the ACL
$acl = Get-Acl $DrivePath
$everyone = [System.Security.Principal.SecurityIdentifier]"S-1-1-0"
$everyoneName = $everyone.Translate([System.Security.Principal.NTAccount])

# Create full control permission
$permission = $everyoneName, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission

# Apply to root
$acl.SetAccessRule($accessRule)
Set-Acl -Path $DrivePath -AclObject $acl -ErrorAction SilentlyContinue

# Apply recursively using icacls (faster than PowerShell)
if ($QuickMode) {
    # Quick mode - common problem folders only
    $problemFolders = @("Users", "Documents and Settings", "ProgramData", "Program Files", "Program Files (x86)")
    foreach ($folder in $problemFolders) {
        $folderPath = Join-Path $DrivePath $folder
        if (Test-Path $folderPath) {
            Write-Host "  Fixing: $folder" -ForegroundColor Gray
            & icacls "$folderPath" /grant "Everyone:(OI)(CI)F" /t /c /q 2>&1 | Out-Null
        }
    }
} else {
    # Full recursive mode
    & icacls "$DrivePath*" /grant "Everyone:(OI)(CI)F" /t /c /q 2>&1 | Out-Null
}

# Step 4: Reset inheritance
Write-Host "Step 4/4: Enabling permission inheritance..." -ForegroundColor Cyan
Show-Progress "Enabling Inheritance" "Processing..."

& icacls $DrivePath /inheritance:e /t /c /q 2>&1 | Out-Null

Write-Progress -Activity "Complete" -Completed

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Permissions fix complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "The drive should now be fully accessible." -ForegroundColor Green
Write-Host ""

if (-not $Silent) {
    Write-Host "If you still have issues with specific folders:" -ForegroundColor Yellow
    Write-Host "1. Right-click the problem folder"
    Write-Host "2. Properties → Security → Advanced"
    Write-Host "3. Click 'Change' next to Owner"
    Write-Host "4. Type 'Everyone' and click OK"
    Write-Host "5. Check 'Replace owner on subcontainers'"
    Write-Host ""
    pause
}