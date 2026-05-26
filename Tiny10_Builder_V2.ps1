# Tiny10 Builder
# Fix Version: V2.1_STABLE (Resolved Path Space & Nesting Bugs)
# Requires: Run as Administrator

param (
    [string]$ISO,
    [string]$SCRATCH
)

# 1. Environment & Path Initialization (Sanitized to fix trailing space bugs)
if (-not $SCRATCH) {
    $ScratchDisk = ($PSScriptRoot).Trim().TrimEnd('\')
} else {
    $ScratchDisk = $SCRATCH.Trim().TrimEnd(':').TrimEnd('\') + ":"
}

# Define base workspaces using native Join-Path (avoids string spaces)
$workspaceDir = Join-Path $ScratchDisk "tiny_workspace"
$scratchDir   = Join-Path $ScratchDisk "scratchdir"

# 2. Localized Security Principle Resolution (Prevents crashes on non-English Windows)
$adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])

# 3. Helper Registry Functions
function Set-RegistryValue {
    param ([string]$path, [string]$name, [string]$type, [string]$value)
    try {
        & 'reg' 'add' $path '/v' $name '/t' $type '/d' $value '/f' | Out-Null
    } catch {
        Write-Warning "Failed setting registry path: $path\$name"
    }
}

function Remove-RegistryValue {
    param ([string]$path)
    try {
        & 'reg' 'delete' $path '/f' | Out-Null
    } catch {
        Write-Warning "Failed removing registry path: $path"
    }
}

# 4. Execution Policy & Administrative Privilege Enforcement
if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Host "PowerShell Execution Policy is Restricted. Changing to RemoteSigned..." -ForegroundColor Yellow
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
}

$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

if (-not $myWindowsPrincipal.IsInRole($adminRole)) {
    Write-Host "Elevating privileges... Re-opening in Administrative context." -ForegroundColor Cyan
    $newProcess = New-Object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $newProcess.Verb = "runas"
    [System.Diagnostics.Process]::Start($newProcess)
    exit
}

# 5. Initialize Build Workspace Logging & Dependencies
$logPath = Join-Path $ScratchDisk "Output.log"
Start-Transcript -Path $logPath -Force

$Host.UI.RawUI.WindowTitle = "Tiny10 Builder"
Clear-Host
Write-Host "====================================================" -ForegroundColor Green
Write-Host "                   Tiny10 Builder                   " -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Green

# Procurement of answers configuration layer
$autounattendPath = Join-Path $ScratchDisk "autounattend.xml"
if (-not (Test-Path $autounattendPath)) {
    Write-Host "Fetching master deployment configuration array..." -ForegroundColor Gray
    Invoke-RestMethod "blob:https://github.com/yuzorhan/Tiny10-Builder/blob/main/autounattend.xml" -OutFile $autounattendPath
}

$removeEdge = Read-Host "Would you like to remove Microsoft Edge? (yes/no)"
$removeOneDrive = Read-Host "Would you like to remove OneDrive? (yes/no)"

# Ensure clean setup directories exist
if (Test-Path $workspaceDir) { Remove-Item $workspaceDir -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $scratchDir) { Remove-Item $scratchDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path (Join-Path $workspaceDir "sources") | Out-Null
New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

# 6. Source Discovery & Drive Analysis (Sanitized to fix drive nesting bug)
do {
    if (-not $ISO) {
        $DriveLetter = Read-Host "Please enter the Drive Letter containing your source Windows installation files"
    } else {
        $DriveLetter = $ISO
    }
    # Clean the input thoroughly to get just the letter
    $DriveLetter = $DriveLetter.Trim().TrimEnd(':').TrimEnd('\').Trim()
    if ($DriveLetter -match '^[c-zC-Z]$') {
        $DriveLetter = $DriveLetter + ":"
        Write-Host "Source drive targeted: $DriveLetter" -ForegroundColor Gray
    } else {
        Write-Host "Invalid entry. Enter a letter between C and Z." -ForegroundColor Red
        $ISO = $null
    }
} while ($DriveLetter -notmatch '^[c-zC-Z]:$')

$installWim = Join-Path $DriveLetter "sources\install.wim"
$installEsd = Join-Path $DriveLetter "sources\install.esd"
$targetWim  = Join-Path $workspaceDir "sources\install.wim"

if (-not (Test-Path $installWim) -and -not (Test-Path $installEsd)) {
    Write-Error "CRITICAL: Could not find install.wim or install.esd inside $DriveLetter\sources\"
    Stop-Transcript; exit 1
}

# Copy metadata and support structures while explicitly ignoring massive install image files
Write-Host "`nCopying base environment mapping structures..." -ForegroundColor Cyan
Copy-Item -Path "$DriveLetter\*" -Destination $workspaceDir -Recurse -Force -Exclude "install.wim","install.esd" -ErrorAction SilentlyContinue | Out-Null

# 7. Image Extraction and Compilation
if (Test-Path $installWim) {
    Write-Host "Source image format identified as WIM." -ForegroundColor Gray
    Get-WindowsImage -ImagePath $installWim
    $index = Read-Host "Select the image index layout you wish to deploy"
    Write-Host "Extracting baseline operating index image..." -ForegroundColor Yellow
    Export-WindowsImage -SourceImagePath $installWim -SourceIndex $index -DestinationImagePath $targetWim -CompressionType Maximum
} elseif (Test-Path $installEsd) {
    Write-Host "Source image format identified as ESD. Converting to manageable structural WIM..." -ForegroundColor Yellow
    Get-WindowsImage -ImagePath $installEsd
    $index = Read-Host "Select the image index layout you wish to deploy"
    Export-WindowsImage -SourceImagePath $installEsd -SourceIndex $index -DestinationImagePath $targetWim -CompressionType Maximum -CheckIntegrity
}

# 8. Mount Target Image Workspace
Clear-Host
Write-Host "Taking explicit ownership of layout image files..." -ForegroundColor Gray
& takeown "/F" $targetWim | Out-Null
& icacls $targetWim "/grant" "$($adminGroup.Value):(F)" | Out-Null
Set-ItemProperty -Path $targetWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

Write-Host "`nMounting Windows image filesystem..." -ForegroundColor Cyan
Mount-WindowsImage -ImagePath $targetWim -Index 1 -Path $scratchDir

# Extract Architecture metadata dynamically for later tool generation
$imageInfo = & 'dism' '/English' '/Get-WimInfo' "/wimFile:$targetWim" "/index:1"
$architecture = "amd64"
if ($imageInfo -match 'Architecture : x86') { $architecture = "x86" }

# 9. Comprehensive Bloatware Package Removal Sequence (Universal Win 10 / 11 List)
Write-Host "`nFiltering system bloatware packages..." -ForegroundColor Cyan
$packages = & dism "/image:$scratchDir" '/Get-ProvisionedAppxPackages' | ForEach-Object {
    if ($_ -match 'PackageName : (.*)') { $matches[1] }
}

$packagePrefixes = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People',
    'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.WindowsSoundRecorder',
    'Microsoft.YourPhone', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'microsoft.windowscommunicationsapps',
    'Clipchamp.Clipchamp', 'Microsoft.Copilot', 'Microsoft.Windows.Copilot', 'Microsoft.OutlookForWindows',
    'Microsoft.PowerAutomateDesktop', 'Microsoft.Wallet', 'Microsoft.Windows.Teams', 'MSTeams',
    'Cortana', 'Microsoft.549981C3F5F10', 'GamingApp', 'Xbox'
)

$packagesToRemove = $packages | Where-Object {
    $pkg = $_
    $null -ne ($packagePrefixes | Where-Object { $pkg -like "*$_*" })
}

foreach ($package in $packagesToRemove) {
    Write-Host "Purging Package: $package" -ForegroundColor DarkYellow
    & dism "/image:$scratchDir" '/Remove-ProvisionedAppxPackage' "/PackageName:$package" | Out-Null
}

# 10. Conditional Application Stripping
if ($removeEdge -eq 'yes') {
    Write-Host "`nRemoving Microsoft Edge binaries and system views..." -ForegroundColor Cyan
    Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\Edge" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\EdgeCore" -Recurse -Force -ErrorAction SilentlyContinue
    & takeown '/f' "$scratchDir\Windows\System32\Microsoft-Edge-Webview" '/r' | Out-Null
    & icacls "$scratchDir\Windows\System32\Microsoft-Edge-Webview" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
    Remove-Item -Path "$scratchDir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue
}

if ($removeOneDrive -eq 'yes') {
    Write-Host "`nRemoving OneDrive provisioning structures..." -ForegroundColor Cyan
    $oneDriveBin = "$scratchDir\Windows\System32\OneDriveSetup.exe"
    if (Test-Path $oneDriveBin) {
        & takeown "/f" $oneDriveBin | Out-Null
        & icacls $oneDriveBin "/grant" "$($adminGroup.Value):(F)" | Out-Null
        Remove-Item -Path $oneDriveBin -Force -ErrorAction SilentlyContinue
    }
}

# 11. Deep Offline Registry Injection (OS Hive Optimization)
Write-Host "`nLoading offline OS Registry structures..." -ForegroundColor Cyan
reg load HKLM\zCOMPONENTS "$scratchDir\Windows\System32\config\COMPONENTS" | Out-Null
reg load HKLM\zDEFAULT "$scratchDir\Windows\System32\config\default" | Out-Null
reg load HKLM\zNTUSER "$scratchDir\Users\Default\ntuser.dat" | Out-Null
reg load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" | Out-Null
reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null

Write-Host "Applying component telemetry and storage optimization flags..." -ForegroundColor Gray
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'

Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'

Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\DiagTrack' 'Start' 'REG_DWORD' '4'
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\WSearch' 'Start' 'REG_DWORD' '4'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'

if ($removeEdge -eq 'yes') {
    Remove-RegistryValue "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
    Remove-RegistryValue "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"
}
if ($removeOneDrive -eq 'yes') {
    Set-RegistryValue "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"
}

# 12. Nuke Diagnostic Scheduled Tasks directly from File System
Write-Host "Purging heavy system diagnostic background tasks..." -ForegroundColor Gray
$tasksPath = "$scratchDir\Windows\System32\Tasks"
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue

Write-Host "Unloading Registry safely..." -ForegroundColor Gray
reg unload HKLM\zCOMPONENTS | Out-Null
reg unload HKLM\zDEFAULT | Out-Null
reg unload HKLM\zNTUSER | Out-Null
reg unload HKLM\zSOFTWARE | Out-Null
reg unload HKLM\zSYSTEM | Out-Null

# 13. Component Cleanup & Unmounting Operations
Write-Host "`nRunning deployment assembly component reduction matrix..." -ForegroundColor Cyan
& dism.exe /Image:"$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null

Write-Host "Saving alterations and unmounting OS installation image..." -ForegroundColor Cyan
Dismount-WindowsImage -Path $scratchDir -Save

# 14. Mount Setup Preinstallation Environment (boot.wim) for Global Compatibility
Write-Host "`nModifying deployment environment boot layout architecture..." -ForegroundColor Cyan
$bootWimPath = Join-Path $workspaceDir "sources\boot.wim"
& takeown "/F" $bootWimPath | Out-Null
& icacls $bootWimPath "/grant" "$($adminGroup.Value):(F)" | Out-Null
Set-ItemProperty -Path $bootWimPath -Name IsReadOnly -Value $false

Mount-WindowsImage -ImagePath $bootWimPath -Index 2 -Path $scratchDir
reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null

Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

reg unload HKLM\zSYSTEM | Out-Null
Dismount-WindowsImage -Path $scratchDir -Save

# 15. Exporting into Ultra-Compacted ESD Deliverable format
Write-Host "`nOptimizing storage size into Ultra-Compact ESD delivery matrix..." -ForegroundColor Cyan
$finalEsd = Join-Path $workspaceDir "sources\install.esd"
& dism.exe /Export-Image /SourceImageFile:$targetWim /SourceIndex:1 /DestinationImageFile:$finalEsd /Compress:fast

Remove-Item -Path $targetWim -Force -ErrorAction SilentlyContinue | Out-Null

# 16. Automated Setup Injections
if (Test-Path $autounattendPath) {
    Write-Host "`nInjecting automatic deployment answers file..." -ForegroundColor Green
    Copy-Item -Path $autounattendPath -Destination (Join-Path $workspaceDir "autounattend.xml") -Force | Out-Null
    Copy-Item -Path $autounattendPath -Destination "$scratchDir\Windows\System32\Sysprep\autounattend.xml" -Force -ErrorAction SilentlyContinue | Out-Null
}

# 17. ISO Compiler Procurement & Execution Matrix
Write-Host "`nLocating image compilation components..." -ForegroundColor Cyan
$ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$architecture\Oscdimg"
$localOSCDIMGPath = Join-Path $ScratchDisk "oscdimg.exe"

if (Test-Path $ADKDepTools) {
    Write-Host "Using native local system deployment ADK tools." -ForegroundColor Gray
    $OSCDIMG = Join-Path $ADKDepTools "oscdimg.exe"
} else {
    Write-Host "ADK workspace absent. Acquiring secure engine from fallback repository..." -ForegroundColor Gray
    if (-not (Test-Path $localOSCDIMGPath)) {
        $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"
        Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath
    }
    $OSCDIMG = $localOSCDIMGPath
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmm"
$isoPath = Join-Path $ScratchDisk "Tiny10_$timestamp.iso"
$bootArgs = "2#p0,e,b`"$workspaceDir\boot\etfsboot.com`"#pEF,e,b`"$workspaceDir\efi\microsoft\boot\efisys.bin`""

Write-Host "Compiling structural installation ISO image file..." -ForegroundColor Yellow
& "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:$bootArgs" "$workspaceDir" "$isoPath"

# 18. Workspace Post-Execution Cleanup Array
Write-Host "`nPerforming final environment cleanup routine checks..." -ForegroundColor Gray
Remove-Item -Path $workspaceDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item -Path $scratchDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item -Path $localOSCDIMGPath -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item -Path $autounattendPath -Force -ErrorAction SilentlyContinue | Out-Null

if ($DriveLetter) {
    Write-Host "Ejecting virtual source drive structures..." -ForegroundColor Gray
    Get-Volume -DriveLetter $DriveLetter[0] | Get-DiskImage | Dismount-DiskImage -ErrorAction SilentlyContinue | Out-Null
}

if ($LASTEXITCODE -eq 0) {
    Write-Host "`nSUCCESS: Tiny10 installation image written cleanly to:`n$isoPath" -ForegroundColor Green
} else {
    Write-Error "CRITICAL COMPILATION ERROR: Structural building terminated abnormally."
}

Stop-Transcript