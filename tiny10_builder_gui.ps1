# Unified Tiny10 Image Builder & Optimizer
# Release Version: 2026-Master
# Requires: Run as Administrator, Windows Source Files (ISO/DVD), and oscdimg.exe

param (
    [string]$ScratchDisk
)

# 1. Environment & Path Initialization
if (-not $ScratchDisk) {
    $ScratchDisk = $PSScriptRoot -replace '[\\]+$', ''
} else {
    $ScratchDisk = $ScratchDisk.TrimEnd(':') + ":"
}

# 2. Execution Policy Guard
if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Host "PowerShell Execution Policy is Restricted. Changing to RemoteSigned for this session..." -ForegroundColor Yellow
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
}

# 3. UAC Administrative Privilege Enforcement
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

if (-not $myWindowsPrincipal.IsInRole($adminRole)) {
    Write-Host "Elevating script privileges... Re-opening in Administrative context." -ForegroundColor Cyan
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $newProcess.Verb = "runas"
    [System.Diagnostics.Process]::Start($newProcess)
    exit
}

# 4. Initialize Build Workspace Logging
$logPath = Join-Path $ScratchDisk "tiny10_builder_master.log"
Start-Transcript -Path $logPath -Force

$Host.UI.RawUI.WindowTitle = "Tiny10 Master Builder"
Clear-Host
Write-Host "====================================================" -ForegroundColor Green
Write-Host "                  Tiny10 Builder                    " -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Green

# 5. User Preferences Prompt
$removeEdge = Read-Host "Would you like to remove Microsoft Edge? (yes/no)"
$removeOneDrive = Read-Host "Would you like to remove OneDrive? (yes/no)"

$hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
$workspaceDir = Join-Path $ScratchDisk "tiny10"
$scratchDir = Join-Path $ScratchDisk "scratchdir"
New-Item -ItemType Directory -Force -Path (Join-Path $workspaceDir "sources") | Out-Null

# 6. Source Discovery & Drive Analysis
do {
    $DriveLetter = Read-Host "Please enter the Drive Letter containing your source Windows 10 installation files"
    $DriveLetter = $DriveLetter.TrimEnd(':')
    if ($DriveLetter -match '^[c-zC-Z]$') {
        $DriveLetter = $DriveLetter + ":"
        Write-Output "Source drive targeted: $DriveLetter"
    } else {
        Write-Host "Invalid entry. Enter a letter between C and Z." -ForegroundColor Red
    }
} while ($DriveLetter -notmatch '^[c-zC-Z]:$')

$installWim = Join-Path $DriveLetter "sources\install.wim"
$installEsd = Join-Path $DriveLetter "sources\install.esd"
$targetWim  = Join-Path $workspaceDir "sources\install.wim"

if (-not (Test-Path $installWim) -and -not (Test-Path $installEsd)) {
    Write-Error "CRITICAL: Could not find install.wim or install.esd inside $DriveLetter\sources\"
    Stop-Transcript; exit 1
}

# 7. File Ingestion & Attribute Cleaning Phase
Write-Host "`nCopying Windows installation base files..." -ForegroundColor Cyan
Copy-Item -Path "$DriveLetter\*" -Destination $workspaceDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

# Critical Fix: Remove Read-Only permissions immediately to prevent DISM manipulation errors
Write-Host "Sanitizing file metadata and removing Read-Only flags..." -ForegroundColor Gray
Get-ChildItem -Path $workspaceDir -Recurse | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }

# Convert ESD if mandatory
if (-not (Test-Path $installWim) -and (Test-Path $installEsd)) {
    Write-Host "Found source image formatted as ESD. Commencing conversion to WIM..." -ForegroundColor Yellow
    Get-WindowsImage -ImagePath $installEsd
    $index = Read-Host "Select the image index layout you wish to deploy"
    Export-WindowsImage -SourceImagePath $installEsd -SourceIndex $index -DestinationImagePath $targetWim -CompressionType Maximum -CheckIntegrity
    if (Test-Path (Join-Path $workspaceDir "sources\install.esd")) {
        Remove-Item (Join-Path $workspaceDir "sources\install.esd") -Force
    }
}

# 8. Mount Target Image Workspace
Clear-Host
Get-WindowsImage -ImagePath $targetWim
$index = Read-Host "Select the specific image index sequence to customize"

Write-Host "`nMounting Windows image architecture filesystem. This can take several minutes..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
Mount-WindowsImage -ImagePath $targetWim -Index $index -Path $scratchDir

# 9. Automated Bloatware Package Removal Sequence
Write-Host "`nFiltering system bloatware packages..." -ForegroundColor Cyan
$packages = & dism "/image:$scratchDir" '/Get-ProvisionedAppxPackages' | ForEach-Object {
    if ($_ -match 'PackageName : (.*)') { $matches[1] }
}

$packagePrefixes = @(
    'Microsoft.BingNews_', 'Microsoft.BingWeather_', 'Microsoft.GetHelp_',
    'Microsoft.Getstarted_', 'Microsoft.MicrosoftOfficeHub_', 'Microsoft.MicrosoftSolitaireCollection_',
    'Microsoft.People_', 'Microsoft.WindowsFeedbackHub_', 'Microsoft.WindowsMaps_',
    'Microsoft.WindowsSoundRecorder_', 'Microsoft.YourPhone_', 'Microsoft.ZuneMusic_',
    'Microsoft.ZuneVideo_', 'microsoft.windowscommunicationsapps_'
)

# Robust logical prefix match fix
$packagesToRemove = $packages | Where-Object {
    $currentPkg = $_
    $matched = $false
    foreach ($prefix in $packagePrefixes) {
        if ($currentPkg -like "$prefix*") { $matched = $true; break }
    }
    $matched
}

foreach ($package in $packagesToRemove) {
    Write-Host "Purging Package: $package" -ForegroundColor DarkYellow
    & dism "/image:$scratchDir" '/Remove-ProvisionedAppxPackage' "/PackageName:$package" | Out-Null
}

# 10. Conditional Application Stripping
if ($removeEdge -eq 'yes') {
    Write-Host "`nRemoving Microsoft Edge binaries..." -ForegroundColor Cyan
    Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\Edge" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\EdgeCore" -Recurse -Force -ErrorAction SilentlyContinue
}

if ($removeOneDrive -eq 'yes') {
    Write-Host "`nRemoving OneDrive provisioning structures..." -ForegroundColor Cyan
    $oneDriveBin = "$scratchDir\Windows\System32\OneDriveSetup.exe"
    if (Test-Path $oneDriveBin) {
        & takeown "/f" $oneDriveBin | Out-Null
        & icacls $oneDriveBin "/grant" "Administrators:(F)" | Out-Null
        Remove-Item -Path $oneDriveBin -Force -ErrorAction SilentlyContinue
    }
}

# 11. Deep Registry Offline Injection
Write-Host "`nLoading offline OS Registry structures..." -ForegroundColor Cyan
reg load HKLM\zDEFAULT "$scratchDir\Windows\System32\config\default" | Out-Null
reg load HKLM\zNTUSER "$scratchDir\Users\Default\ntuser.dat" | Out-Null
reg load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" | Out-Null
reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null

Write-Host "Applying component telemetry restrictions..." -ForegroundColor Gray
& reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "OemPreInstalledAppsEnabled" /t REG_DWORD /d 0 /f | Out-Null
& reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "PreInstalledAppsEnabled" /t REG_DWORD /d 0 /f | Out-Null
& reg add "HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v "SilentInstalledAppsEnabled" /t REG_DWORD /d 0 /f | Out-Null
& reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent" /v "DisableWindowsConsumerFeatures" /t REG_DWORD /d 1 /f | Out-Null
& reg add "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v "Enabled" /t REG_DWORD /d 0 /f | Out-Null
& reg add "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" /v "TailoredExperiencesWithDiagnosticDataEnabled" /t REG_DWORD /d 0 /f | Out-Null
& reg add "HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d 0 /f | Out-Null

# Offline Service Deactivation Ported from Optimizer Script
Write-Host "Disabling heavy background services offline..." -ForegroundColor Gray
& reg add "HKLM\zSYSTEM\ControlSet001\Services\DiagTrack" /v "Start" /t REG_DWORD /d 4 /f | Out-Null
& reg add "HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice" /v "Start" /t REG_DWORD /d 4 /f | Out-Null
& reg add "HKLM\zSYSTEM\ControlSet001\Services\WSearch" /v "Start" /t REG_DWORD /d 4 /f | Out-Null

Write-Host "Unloading Registry safely..." -ForegroundColor Gray
reg unload HKLM\zDEFAULT | Out-Null
reg unload HKLM\zNTUSER | Out-Null
reg unload HKLM\zSOFTWARE | Out-Null
reg unload HKLM\zSYSTEM | Out-Null

# 12. Component Cleanup & Unmounting Operations
Write-Host "`nRunning deep deployment assembly base component cleanup..." -ForegroundColor Cyan
& dism.exe /Image:"$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null

Write-Host "Saving alterations and unmounting target WIM image..." -ForegroundColor Cyan
Dismount-WindowsImage -Path $scratchDir -Save

Write-Host "Optimizing compression storage sizing matrix..." -ForegroundColor Cyan
$finalWim = Join-Path $workspaceDir "sources\install2.wim"
Export-WindowsImage -SourceImagePath $targetWim -SourceIndex $index -DestinationImagePath $finalWim -CompressionType Fast
Remove-Item -Path $targetWim -Force | Out-Null
Rename-Item -Path $finalWim -NewName "install.wim" | Out-Null

# 13. Automated Setup Injections
$autounattendSrc = Join-Path $PSScriptRoot "autounattend.xml"
if (Test-Path $autounattendSrc) {
    Write-Host "`nInjecting autounattend.xml configuration array..." -ForegroundColor Green
    Copy-Item -Path $autounattendSrc -Destination (Join-Path $workspaceDir "autounattend.xml") -Force | Out-Null
}

# 14. ISO Image Construction Setup
Write-Host "`nLocating compilation binary rules..." -ForegroundColor Cyan
$localOSCDIMG = Join-Path $PSScriptRoot "oscdimg.exe"
$adkOSCDIMG = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostArchitecture\Oscdimg\oscdimg.exe"

if (Test-Path $adkOSCDIMG) {
    $OSCDIMG = $adkOSCDIMG
    Write-Host "Using system Windows ADK deployment binaries." -ForegroundColor Gray
} elseif (Test-Path $localOSCDIMG) {
    $OSCDIMG = $localOSCDIMG
    Write-Host "Using workspace internal bundled execution binaries." -ForegroundColor Gray
} else {
    Write-Error "CRITICAL: oscdimg.exe missing. Place the utility in: $PSScriptRoot"
    Stop-Transcript; exit 1
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$isoPath = Join-Path $PSScriptRoot "tiny10_delivery_$timestamp.iso"
$bootArgs = "2#p0,e,b`"$workspaceDir\boot\etfsboot.com`"#pEF,e,b`"$workspaceDir\efi\microsoft\boot\efisys.bin`""

Write-Host "Compiling bootable storage ISO container architecture..." -ForegroundColor Yellow
& "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:$bootArgs" "$workspaceDir" "$isoPath"

# 15. Workspace Cleanup Operations
if ($LASTEXITCODE -eq 0) {
    Write-Host "`nSUCCESS: Bootable ISO generated cleanly at: $isoPath" -ForegroundColor Green
    Write-Host "Running cleanup on staging directories..." -ForegroundColor Gray
    Remove-Item -Path $workspaceDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path $scratchDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
} else {
    Write-Error "CRITICAL FAILURE: ISO compiler threw exit code return: $LASTEXITCODE"
}

Stop-Transcript
