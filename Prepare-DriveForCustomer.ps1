# Prepare Drive for Customer Handoff
# Version: 1.0
# Purpose: Complete checklist for preparing recovered drives
# Run as Administrator

#Requires -RunAsAdministrator

param(
    [string]$DriveLetter = "",
    [switch]$GenerateReport = $true
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   Drive Preparation for Customer" -ForegroundColor Cyan
Write-Host "   Data Recovery Final Steps" -ForegroundColor Cyan  
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get drive letter if not provided
if (-not $DriveLetter) {
    $DriveLetter = Read-Host "Enter drive letter to prepare (e.g., E)"
}

$DriveLetter = $DriveLetter.TrimEnd(':') + ':'
$DrivePath = $DriveLetter + '\'

# Validate drive
if (-not (Test-Path $DrivePath)) {
    Write-Host "ERROR: Drive $DriveLetter does not exist!" -ForegroundColor Red
    pause
    exit 1
}

# Initialize report
$reportPath = "$DrivePath\RECOVERY_REPORT.txt"
$report = @()
$report += "Data Recovery Report"
$report += "===================="
$report += "Generated: $(Get-Date)"
$report += "Drive: $DriveLetter"
$report += ""

# Step 1: Drive Information
Write-Host "Step 1: Gathering drive information..." -ForegroundColor Yellow
$volume = Get-Volume -DriveLetter $DriveLetter.TrimEnd(':')
$report += "Drive Information:"
$report += "  Label: $($volume.FileSystemLabel)"
$report += "  File System: $($volume.FileSystem)"
$report += "  Total Size: $([math]::Round($volume.Size / 1GB, 2)) GB"
$report += "  Free Space: $([math]::Round($volume.SizeRemaining / 1GB, 2)) GB"
$report += "  Used Space: $([math]::Round(($volume.Size - $volume.SizeRemaining) / 1GB, 2)) GB"
$report += ""

# Step 2: Check for recovery artifacts
Write-Host "Step 2: Checking for recovery artifacts..." -ForegroundColor Yellow
$artifacts = @()

# Check for common recovery files
$recoveryFiles = @(
    "recovery_manifest*.txt",
    "rsync_recovery_manifest*.txt",
    "folder_summary.txt",
    "symlinks_map.txt",
    "REORGANIZATION_INFO.txt",
    "deferred_files_*.txt"
)

foreach ($pattern in $recoveryFiles) {
    $found = Get-ChildItem -Path $DrivePath -Filter $pattern -ErrorAction SilentlyContinue
    if ($found) {
        $artifacts += $found
        Write-Host "  Found: $($found.Name)" -ForegroundColor Gray
    }
}

if ($artifacts.Count -gt 0) {
    $report += "Recovery Artifacts Found:"
    foreach ($artifact in $artifacts) {
        $report += "  - $($artifact.Name)"
    }
    $report += ""
    
    $cleanup = Read-Host "Move recovery artifacts to '_Recovery_Info' folder? (Y/N)"
    if ($cleanup -eq 'Y') {
        $infoPath = "$DrivePath\_Recovery_Info"
        New-Item -ItemType Directory -Path $infoPath -Force | Out-Null
        foreach ($artifact in $artifacts) {
            Move-Item -Path $artifact.FullName -Destination $infoPath -Force
            Write-Host "  Moved: $($artifact.Name)" -ForegroundColor Green
        }
        $report += "Artifacts moved to: \_Recovery_Info folder"
        $report += ""
    }
}

# Step 3: Check for problem indicators
Write-Host "Step 3: Checking for potential issues..." -ForegroundColor Yellow
$issues = @()

# Check for encrypted files
$encryptedFiles = Get-ChildItem -Path $DrivePath -Recurse -Attributes Encrypted -ErrorAction SilentlyContinue | Select-Object -First 10
if ($encryptedFiles) {
    $issues += "Found encrypted files - customer may need encryption keys"
    Write-Host "  WARNING: Found encrypted files" -ForegroundColor Red
}

# Check for very long paths
$longPaths = Get-ChildItem -Path $DrivePath -Recurse -ErrorAction SilentlyContinue | 
    Where-Object { $_.FullName.Length -gt 250 } | Select-Object -First 10
if ($longPaths) {
    $issues += "Found paths longer than 250 characters - may cause issues"
    Write-Host "  WARNING: Found very long file paths" -ForegroundColor Yellow
}

# Check for special characters in filenames
$specialChars = Get-ChildItem -Path $DrivePath -Recurse -ErrorAction SilentlyContinue | 
    Where-Object { $_.Name -match '[<>:"|?*]' } | Select-Object -First 10
if ($specialChars) {
    $issues += "Found files with special characters - may cause issues"
    Write-Host "  WARNING: Found files with special characters" -ForegroundColor Yellow
}

if ($issues.Count -gt 0) {
    $report += "Potential Issues:"
    foreach ($issue in $issues) {
        $report += "  - $issue"
    }
    $report += ""
}

# Step 4: Create file inventory
Write-Host "Step 4: Creating file inventory..." -ForegroundColor Yellow
$fileStats = @{}
$extensions = Get-ChildItem -Path $DrivePath -Recurse -File -ErrorAction SilentlyContinue | 
    Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 20

$report += "Top File Types Recovered:"
foreach ($ext in $extensions) {
    $sizeMB = [math]::Round(($ext.Group | Measure-Object Length -Sum).Sum / 1MB, 2)
    $report += "  $($ext.Name): $($ext.Count) files ($sizeMB MB)"
}
$report += ""

# Step 5: Test file accessibility
Write-Host "Step 5: Testing file accessibility..." -ForegroundColor Yellow
$testFolders = @("Users", "Documents", "Pictures", "Desktop")
$accessibleCount = 0
$inaccessibleCount = 0

foreach ($folder in $testFolders) {
    $testPath = Join-Path $DrivePath $folder
    if (Test-Path $testPath) {
        try {
            $files = Get-ChildItem -Path $testPath -ErrorAction Stop | Select-Object -First 1
            $accessibleCount++
            Write-Host "  ✓ $folder - Accessible" -ForegroundColor Green
        } catch {
            $inaccessibleCount++
            Write-Host "  ✗ $folder - Access Denied" -ForegroundColor Red
        }
    }
}

$report += "Accessibility Test:"
$report += "  Accessible folders: $accessibleCount"
$report += "  Inaccessible folders: $inaccessibleCount"
$report += ""

if ($inaccessibleCount -gt 0) {
    Write-Host ""
    Write-Host "Some folders are not accessible!" -ForegroundColor Red
    $fixPerms = Read-Host "Run permissions fix now? (Y/N)"
    if ($fixPerms -eq 'Y') {
        & "$PSScriptRoot\Fix-NTFSPermissions.ps1" -DriveLetter $DriveLetter.TrimEnd(':')
    }
}

# Step 6: Generate summary
Write-Host "Step 6: Generating summary..." -ForegroundColor Yellow

# Count total files and folders
$totalFiles = (Get-ChildItem -Path $DrivePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
$totalFolders = (Get-ChildItem -Path $DrivePath -Recurse -Directory -ErrorAction SilentlyContinue | Measure-Object).Count

$report += "Recovery Summary:"
$report += "  Total Files: $totalFiles"
$report += "  Total Folders: $totalFolders"
$report += "  Drive Usage: $([math]::Round((($volume.Size - $volume.SizeRemaining) / $volume.Size) * 100, 1))%"
$report += ""

# Final recommendations
$report += "Recommendations for Customer:"
$report += "  1. Create a backup of this recovered data immediately"
$report += "  2. Scan for viruses/malware before regular use"
$report += "  3. Check important files to ensure they open correctly"
$report += "  4. Some files may be corrupted - this is normal with failing drives"
$report += "  5. Cloud sync folders (OneDrive, Dropbox) may need to be re-linked"
$report += ""

# Save report
if ($GenerateReport) {
    $report | Out-File -FilePath $reportPath -Encoding UTF8
    Write-Host ""
    Write-Host "Report saved to: $reportPath" -ForegroundColor Green
}

# Display summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Drive Preparation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Files recovered: $totalFiles" 
Write-Host "  Folders recovered: $totalFolders"
Write-Host "  Drive usage: $([math]::Round((($volume.Size - $volume.SizeRemaining) / $volume.Size) * 100, 1))%"
Write-Host ""

# Final checklist
Write-Host "Final Checklist:" -ForegroundColor Yellow
Write-Host "  [ ] CHKDSK completed"
Write-Host "  [ ] Permissions fixed" 
Write-Host "  [ ] Recovery artifacts organized"
Write-Host "  [ ] Report generated"
Write-Host "  [ ] Test files accessible"
Write-Host "  [ ] No malware detected (if scanned)"
Write-Host ""
Write-Host "The drive is ready for customer handoff!" -ForegroundColor Green
Write-Host ""
pause