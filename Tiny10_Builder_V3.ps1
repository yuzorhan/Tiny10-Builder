#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a lightweight Windows 10 ISO by removing bloatware and telemetry.

.DESCRIPTION
    Tiny10 Builder takes a standard Windows source ISO, removes unwanted packages
    and services, applies privacy/performance registry tweaks, and recompiles a
    smaller bootable ISO image.

.PARAMETER ISO
    Drive letter of the mounted Windows source ISO (e.g. D).

.PARAMETER SCRATCH
    Drive letter to use as the working scratch space (e.g. C or E).
    Defaults to the script's own directory — it is recommended to always pass
    a drive letter here to avoid burying workspace files in unexpected places.

.PARAMETER KeepEdge
    Skip removal of Microsoft Edge. Overrides the interactive prompt.

.PARAMETER KeepOneDrive
    Skip removal of OneDrive. Overrides the interactive prompt.

.PARAMETER SkipCleanup
    Do not delete workspace directories after building. Useful for debugging.

.EXAMPLE
    # Interactive — the script will ask all questions
    .\Tiny10Builder.ps1

.EXAMPLE
    # Specify drives, still prompts for Edge/OneDrive
    .\Tiny10Builder.ps1 -ISO E -SCRATCH C

.EXAMPLE
    # Fully automated, no prompts
    .\Tiny10Builder.ps1 -ISO E -SCRATCH C -KeepEdge -KeepOneDrive

.EXAMPLE
    # Keep workspace after build for debugging
    .\Tiny10Builder.ps1 -ISO E -SCRATCH C -SkipCleanup
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string]$ISO,
    [string]$SCRATCH,
    [switch]$KeepEdge,
    [switch]$KeepOneDrive,
    [switch]$SkipCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Path Initialization ────────────────────────────────────────────────────────
# FIX V3: If no -SCRATCH is given, default to the script's drive root (e.g. C:)
# instead of $PSScriptRoot. This prevents workspace files being buried inside
# Downloads or other deep paths which confuses the disk-space check and can
# cause path-length issues on long directory names.
if (-not $SCRATCH) {
    $ScratchDisk = Split-Path -Qualifier $PSScriptRoot   # e.g. "C:"
} else {
    $ScratchDisk = $SCRATCH.Trim().TrimEnd(':').TrimEnd('\') + ':'
}

$workspaceDir     = Join-Path $ScratchDisk 'tiny_workspace'
$scratchDir       = Join-Path $ScratchDisk 'scratchdir'
$logPath          = Join-Path $ScratchDisk 'Output.log'
$autounattendPath = Join-Path $ScratchDisk 'autounattend.xml'
$localOSCDIMGPath = Join-Path $ScratchDisk 'oscdimg.exe'

# Declared before try so the finally block can always safely reference them
$DriveLetter    = $null
$removeEdge     = $false
$removeOneDrive = $false
$osEdition      = 'Unknown'

# ── Security Principal (Localized, works on non-English Windows) ───────────────
$adminSID   = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])

# ── Helper Functions ───────────────────────────────────────────────────────────
$script:stepTotal   = 17
$script:stepCurrent = 0

function Write-Log {
    param([string]$Message, [ConsoleColor]$Color = 'White')
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $Message" -ForegroundColor $Color
}

function Write-Step {
    param([string]$Message)
    $script:stepCurrent++
    $pct = [int](($script:stepCurrent / $script:stepTotal) * 100)
    Write-Progress -Activity 'Tiny10 Builder' `
        -Status "Step $($script:stepCurrent)/$($script:stepTotal): $Message" `
        -PercentComplete $pct
    Write-Log "── Step $($script:stepCurrent)/$($script:stepTotal): $Message ──" -Color Cyan
}

function Set-RegistryValue {
    param([string]$Path, [string]$Name, [string]$Type, [string]$Value)
    if ($PSCmdlet.ShouldProcess("$Path\$Name", 'Set registry value')) {
        try   { & reg add $Path /v $Name /t $Type /d $Value /f | Out-Null }
        catch { Write-Warning "Registry set failed: $Path\$Name — $_" }
    }
}

function Remove-RegistryValue {
    param([string]$Path)
    if ($PSCmdlet.ShouldProcess($Path, 'Delete registry key')) {
        try   { & reg delete $Path /f | Out-Null }
        catch { Write-Warning "Registry delete failed: $Path — $_" }
    }
}

function Read-YesNo {
    param([string]$Prompt)
    do {
        $a = (Read-Host $Prompt).Trim().ToLower()
        if ($a -notin 'yes','y','no','n') {
            Write-Host 'Please enter yes/no (or y/n).' -ForegroundColor Red
        }
    } while ($a -notin 'yes','y','no','n')
    return ($a -in 'yes','y')
}

function Assert-FreeSpace {
    param([string]$Drive, [int]$RequiredGB)
    # Use just the drive letter character for Get-PSDrive
    $letter = $Drive.TrimEnd(':')[0]
    $vol = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    if ($vol) {
        $freeGB = [math]::Round($vol.Free / 1GB, 1)
        if ($vol.Free -lt ($RequiredGB * 1GB)) {
            throw "Insufficient disk space on ${Drive}. Need ${RequiredGB} GB, have ${freeGB} GB."
        }
        Write-Log "Disk space OK: ${freeGB} GB free on ${Drive}." -Color Gray
    } else {
        Write-Warning "Could not check disk space on ${Drive} — continuing anyway."
    }
}

function Unload-AllHives {
    foreach ($hive in 'zCOMPONENTS','zDEFAULT','zNTUSER','zSOFTWARE','zSYSTEM') {
        reg unload "HKLM\$hive" 2>$null | Out-Null
    }
}

# FIX V3.1: Dismount ALL currently mounted WIM images, not just the current
# $scratchDir path. The old check missed stale mounts from previous runs that
# used a different working directory, causing "image already mounted" errors.
function Dismount-AllStaleMounts {
    $allMounted = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue
    if ($allMounted) {
        foreach ($mount in $allMounted) {
            Write-Log "Dismounting stale WIM at: $($mount.Path)" -Color Yellow
            Dismount-WindowsImage -Path $mount.Path -Discard -ErrorAction SilentlyContinue
        }
    }
}

# ── Execution Policy & Elevation ───────────────────────────────────────────────
if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Host 'Changing execution policy to RemoteSigned...' -ForegroundColor Yellow
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
}

$principal = New-Object System.Security.Principal.WindowsPrincipal(
    [System.Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Re-launching as Administrator...' -ForegroundColor Cyan
    $p           = New-Object System.Diagnostics.ProcessStartInfo 'PowerShell'
    $p.Arguments = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $p.Verb      = 'runas'
    [System.Diagnostics.Process]::Start($p)
    exit
}

# ── Transcript ─────────────────────────────────────────────────────────────────
Start-Transcript -Path $logPath -Force

$Host.UI.RawUI.WindowTitle = 'Tiny10 Builder'
Clear-Host
Write-Host '════════════════════════════════════════════' -ForegroundColor Green
Write-Host '               Tiny10 Builder               ' -ForegroundColor Green
Write-Host '════════════════════════════════════════════' -ForegroundColor Green
Write-Host "  Scratch drive : $ScratchDisk" -ForegroundColor Gray
Write-Host "  Workspace     : $workspaceDir" -ForegroundColor Gray
Write-Host "  Log           : $logPath" -ForegroundColor Gray
Write-Host '════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''

# ── Build state flags (used by finally block) ──────────────────────────────────
$script:installWimMounted = $false
$script:bootWimMounted    = $false
$script:hivesLoaded       = $false
$script:removedPackages   = [System.Collections.Generic.List[string]]::new()
$script:buildSuccess      = $false

try {

    # ── Step 1: Fetch autounattend.xml ─────────────────────────────────────────
    Write-Step 'Fetching answer file'
    if (-not (Test-Path $autounattendPath)) {
        try {
            Invoke-RestMethod `
                'https://raw.githubusercontent.com/yuzorhan/Tiny10-Builder/main/autounattend.xml' `
                -OutFile $autounattendPath
            Write-Log 'autounattend.xml downloaded.' -Color Gray
        } catch {
            Write-Warning "Could not fetch autounattend.xml — continuing without it. $_"
        }
    } else {
        Write-Log 'autounattend.xml already present — skipping download.' -Color Gray
    }

    # ── Step 2: Build Options ──────────────────────────────────────────────────
    Write-Step 'Gathering build options'
    $removeEdge     = if ($KeepEdge)     { $false } else { Read-YesNo 'Remove Microsoft Edge?   (yes/no)' }
    $removeOneDrive = if ($KeepOneDrive) { $false } else { Read-YesNo 'Remove OneDrive?          (yes/no)' }

    # ── Step 3: Source Drive Selection ────────────────────────────────────────
    Write-Step 'Selecting source drive'
    do {
        if (-not $ISO) {
            $DriveLetter = Read-Host 'Enter the drive letter of your mounted Windows ISO (e.g. D)'
        } else {
            $DriveLetter = $ISO
        }
        $DriveLetter = $DriveLetter.Trim().TrimEnd(':').TrimEnd('\').Trim()
        if ($DriveLetter -match '^[c-zC-Z]$') {
            $DriveLetter += ':'
            Write-Log "Source drive: $DriveLetter" -Color Gray
        } else {
            Write-Host 'Invalid. Enter a single letter C–Z.' -ForegroundColor Red
            $ISO = $null
        }
    } while ($DriveLetter -notmatch '^[c-zC-Z]:$')

    $installWim = Join-Path $DriveLetter 'sources\install.wim'
    $installEsd = Join-Path $DriveLetter 'sources\install.esd'
    $targetWim  = Join-Path $workspaceDir 'sources\install.wim'

    if (-not (Test-Path $installWim) -and -not (Test-Path $installEsd)) {
        throw "Cannot find install.wim or install.esd in $DriveLetter\sources\ — make sure the ISO is mounted."
    }

    # ── Step 4: Disk Space Check ───────────────────────────────────────────────
    Write-Step 'Checking available disk space'
    Assert-FreeSpace -Drive $ScratchDisk -RequiredGB 25

    # ── Step 5: Workspace Initialization ──────────────────────────────────────
    Write-Step 'Initializing build workspace'
    foreach ($dir in $workspaceDir, $scratchDir) {
        if (Test-Path $dir) {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $workspaceDir 'sources') | Out-Null
    New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
    Write-Log "Workspace ready at: $workspaceDir" -Color Gray

    # ── Step 6: Copy Source Files ──────────────────────────────────────────────
    Write-Step 'Copying ISO source structure (this may take a few minutes)'
    # Using Get-ChildItem pipeline because Copy-Item -Exclude with -Recurse in
    # PowerShell 5 only filters the top-level path, not subdirectory contents.
    # install.wim/esd are inside sources\ so -Exclude would not have caught them.
    Get-ChildItem -Path $DriveLetter -Recurse -Exclude 'install.wim','install.esd' |
        Where-Object { -not $_.PSIsContainer } |
        ForEach-Object {
            $dest    = $_.FullName.Replace($DriveLetter, $workspaceDir)
            $destDir = Split-Path $dest -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            }
            Copy-Item -Path $_.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
        }

    # ── Step 7: Image Extraction ───────────────────────────────────────────────
    Write-Step 'Extracting Windows image (this takes the longest — up to 20 min)'
    if (Test-Path $installWim) {
        Write-Log 'Format: WIM' -Color Gray
        Get-WindowsImage -ImagePath $installWim
        $index = Read-Host 'Select image index (e.g. 6 for Pro)'
        Export-WindowsImage -SourceImagePath $installWim -SourceIndex $index `
            -DestinationImagePath $targetWim -CompressionType Maximum
    } else {
        Write-Log 'Format: ESD — converting to WIM...' -Color Yellow
        Get-WindowsImage -ImagePath $installEsd
        $index = Read-Host 'Select image index (e.g. 6 for Pro)'
        Export-WindowsImage -SourceImagePath $installEsd -SourceIndex $index `
            -DestinationImagePath $targetWim -CompressionType Maximum -CheckIntegrity
    }

    # ── Step 8: Mount Install Image ────────────────────────────────────────────
    Write-Step 'Mounting Windows image'
    & takeown "/F" $targetWim | Out-Null
    & icacls $targetWim "/grant" "$($adminGroup.Value):(F)" | Out-Null
    Set-ItemProperty -Path $targetWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

    # FIX V3.1: Dismount ALL stale WIM mounts before attempting to mount.
    # The old check only looked for a mount at the current $scratchDir path,
    # so it missed mounts from previous runs that used a different directory
    # (e.g. running from Downloads vs running with -SCRATCH C).
    Write-Log 'Clearing any stale WIM mounts...' -Color Gray
    Dismount-AllStaleMounts

    Write-Log 'Mounting install.wim...' -Color Gray
    Mount-WindowsImage -ImagePath $targetWim -Index 1 -Path $scratchDir
    $script:installWimMounted = $true

    # Architecture detection via WIM metadata API (more reliable than dism text parsing)
    $wimInfo      = Get-WindowsImage -ImagePath $targetWim -Index 1
    $architecture = if ($wimInfo.Architecture -eq 0) { 'x86' } else { 'amd64' }
    $osEdition    = $wimInfo.ImageName
    Write-Log "Detected: $osEdition ($architecture)" -Color Gray

    # ── Step 9: Bloatware Package Removal ─────────────────────────────────────
    Write-Step 'Removing bloatware packages'
    $packages = & dism "/image:$scratchDir" '/Get-ProvisionedAppxPackages' |
        ForEach-Object { if ($_ -match 'PackageName : (.*)') { $matches[1] } }

    $packagePrefixes = @(
        'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp','Microsoft.Getstarted',
        'Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection','Microsoft.People',
        'Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps','Microsoft.WindowsSoundRecorder',
        'Microsoft.YourPhone','Microsoft.ZuneMusic','Microsoft.ZuneVideo',
        'microsoft.windowscommunicationsapps','Clipchamp.Clipchamp','Microsoft.Copilot',
        'Microsoft.Windows.Copilot','Microsoft.OutlookForWindows','Microsoft.PowerAutomateDesktop',
        'Microsoft.Wallet','Microsoft.Windows.Teams','MSTeams','Cortana',
        'Microsoft.549981C3F5F10','GamingApp','Xbox'
    )

    $toRemove = $packages | Where-Object {
        $pkg = $_
        $packagePrefixes | Where-Object { $pkg -like "*$_*" }
    }

    foreach ($pkg in $toRemove) {
        Write-Log "  Removing: $pkg" -Color DarkYellow
        & dism "/image:$scratchDir" '/Remove-ProvisionedAppxPackage' "/PackageName:$pkg" | Out-Null
        $script:removedPackages.Add($pkg)
    }
    Write-Log "$($script:removedPackages.Count) package(s) removed." -Color Green

    # ── Step 10: Edge / OneDrive File Removal ─────────────────────────────────
    Write-Step 'Removing optional components'
    if ($removeEdge) {
        Write-Log 'Removing Microsoft Edge binaries...' -Color Gray
        foreach ($p in @(
            "$scratchDir\Program Files (x86)\Microsoft\Edge",
            "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate",
            "$scratchDir\Program Files (x86)\Microsoft\EdgeCore"
        )) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }

        $webview = "$scratchDir\Windows\System32\Microsoft-Edge-Webview"
        if (Test-Path $webview) {
            & takeown '/f' $webview '/r' | Out-Null
            & icacls $webview '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
            Remove-Item -Path $webview -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log 'Edge removed.' -Color Gray
    } else {
        Write-Log 'Keeping Edge (skipped).' -Color Gray
    }

    if ($removeOneDrive) {
        Write-Log 'Removing OneDrive setup binary...' -Color Gray
        $odBin = "$scratchDir\Windows\System32\OneDriveSetup.exe"
        if (Test-Path $odBin) {
            & takeown "/f" $odBin | Out-Null
            & icacls $odBin "/grant" "$($adminGroup.Value):(F)" | Out-Null
            Remove-Item -Path $odBin -Force -ErrorAction SilentlyContinue
        }
        Write-Log 'OneDrive removed.' -Color Gray
    } else {
        Write-Log 'Keeping OneDrive (skipped).' -Color Gray
    }

    # ── Step 11: Offline Registry Tweaks ──────────────────────────────────────
    Write-Step 'Applying offline registry optimizations'
    reg load HKLM\zCOMPONENTS "$scratchDir\Windows\System32\config\COMPONENTS" | Out-Null
    reg load HKLM\zDEFAULT    "$scratchDir\Windows\System32\config\default"    | Out-Null
    reg load HKLM\zNTUSER      "$scratchDir\Users\Default\ntuser.dat"           | Out-Null
    reg load HKLM\zSOFTWARE    "$scratchDir\Windows\System32\config\SOFTWARE"   | Out-Null
    reg load HKLM\zSYSTEM      "$scratchDir\Windows\System32\config\SYSTEM"     | Out-Null
    $script:hivesLoaded = $true

    # Unsupported hardware notification suppression
    foreach ($hive in 'zDEFAULT','zNTUSER') {
        Set-RegistryValue "HKLM\$hive\Control Panel\UnsupportedHardwareNotificationCache" 'SV1' 'REG_DWORD' '0'
        Set-RegistryValue "HKLM\$hive\Control Panel\UnsupportedHardwareNotificationCache" 'SV2' 'REG_DWORD' '0'
    }

    # Content delivery / advertising
    $cdm = 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Set-RegistryValue $cdm 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue $cdm 'PreInstalledAppsEnabled'    'REG_DWORD' '0'
    Set-RegistryValue $cdm 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' `
        'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' `
        'Enabled' 'REG_DWORD' '0'

    # Telemetry
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' `
        'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' `
        'AllowTelemetry' 'REG_DWORD' '0'

    # Hardware requirement bypasses
    $labConfig = 'HKLM\zSYSTEM\Setup\LabConfig'
    foreach ($key in 'BypassCPUCheck','BypassRAMCheck','BypassSecureBootCheck','BypassStorageCheck','BypassTPMCheck') {
        Set-RegistryValue $labConfig $key 'REG_DWORD' '1'
    }
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

    # Disable heavy background services
    foreach ($svc in 'DiagTrack','dmwappushservice','WSearch') {
        Set-RegistryValue "HKLM\zSYSTEM\ControlSet001\Services\$svc" 'Start' 'REG_DWORD' '4'
    }

    # Storage reserves & BitLocker auto-encryption
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' `
        'ShippedWithReserves' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' `
        'PreventDeviceEncryption' 'REG_DWORD' '1'

    if ($removeEdge) {
        Remove-RegistryValue 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
        Remove-RegistryValue 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update'
    }
    if ($removeOneDrive) {
        Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 'REG_DWORD' '1'
    }

    Unload-AllHives
    $script:hivesLoaded = $false
    Write-Log 'Registry hives unloaded.' -Color Gray

    # ── Step 12: Scheduled Task Removal ───────────────────────────────────────
    Write-Step 'Removing diagnostic scheduled tasks'
    $tasks = "$scratchDir\Windows\System32\Tasks\Microsoft\Windows"
    Remove-Item "$tasks\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
    Remove-Item "$tasks\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$tasks\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
    Remove-Item "$tasks\Windows Error Reporting\QueueReporting"    -Force -ErrorAction SilentlyContinue

    # ── Step 13: Component Cleanup & Dismount Install Image ───────────────────
    Write-Step 'Running component cleanup and saving install image'
    Write-Log 'Running DISM cleanup (this can take several minutes)...' -Color Gray
    & dism.exe /Image:"$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null

    Write-Log 'Saving and dismounting install.wim...' -Color Gray
    Dismount-WindowsImage -Path $scratchDir -Save
    $script:installWimMounted = $false

    # ── Step 14: Boot Environment Patching ────────────────────────────────────
    Write-Step 'Patching boot environment (boot.wim)'
    $bootWimPath = Join-Path $workspaceDir 'sources\boot.wim'
    & takeown "/F" $bootWimPath | Out-Null
    & icacls $bootWimPath "/grant" "$($adminGroup.Value):(F)" | Out-Null
    Set-ItemProperty -Path $bootWimPath -Name IsReadOnly -Value $false

    # FIX V3.1: Same stale-mount clearance applied here too
    Dismount-AllStaleMounts

    Write-Log 'Mounting boot.wim...' -Color Gray
    Mount-WindowsImage -ImagePath $bootWimPath -Index 2 -Path $scratchDir
    $script:bootWimMounted = $true

    reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null
    foreach ($key in 'BypassCPUCheck','BypassRAMCheck','BypassSecureBootCheck','BypassStorageCheck','BypassTPMCheck') {
        Set-RegistryValue $labConfig $key 'REG_DWORD' '1'
    }
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
    reg unload HKLM\zSYSTEM | Out-Null

    Write-Log 'Saving and dismounting boot.wim...' -Color Gray
    Dismount-WindowsImage -Path $scratchDir -Save
    $script:bootWimMounted = $false

    # ── Step 15: Export to Compact ESD ────────────────────────────────────────
    Write-Step 'Exporting to compact ESD format'
    $finalEsd = Join-Path $workspaceDir 'sources\install.esd'
    & dism.exe /Export-Image /SourceImageFile:$targetWim /SourceIndex:1 `
        /DestinationImageFile:$finalEsd /Compress:fast
    Remove-Item -Path $targetWim -Force -ErrorAction SilentlyContinue

    # ── Step 16: Inject Answer File ────────────────────────────────────────────
    Write-Step 'Injecting autounattend.xml'
    # NOTE: Only copied to workspace root (ISO root). The old script also tried
    # to copy into scratchDir\Windows\System32\Sysprep\ but both WIMs are
    # dismounted by this point so that was a silent no-op — removed.
    if (Test-Path $autounattendPath) {
        Copy-Item -Path $autounattendPath `
            -Destination (Join-Path $workspaceDir 'autounattend.xml') -Force
        Write-Log 'autounattend.xml injected.' -Color Gray
    } else {
        Write-Log 'No autounattend.xml found — skipping.' -Color Yellow
    }

    # ── Step 17: Compile ISO ───────────────────────────────────────────────────
    Write-Step 'Compiling final ISO image'
    $ADKPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit" +
               "\Deployment Tools\$architecture\Oscdimg"

    if (Test-Path $ADKPath) {
        Write-Log 'Using installed ADK oscdimg.' -Color Gray
        $OSCDIMG = Join-Path $ADKPath 'oscdimg.exe'
    } else {
        Write-Log 'ADK not found — downloading oscdimg from symbol server...' -Color Yellow
        if (-not (Test-Path $localOSCDIMGPath)) {
            Invoke-WebRequest `
                'https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe' `
                -OutFile $localOSCDIMGPath
        }
        $OSCDIMG = $localOSCDIMGPath
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $isoPath   = Join-Path $ScratchDisk "Tiny10_$timestamp.iso"
    $bootArgs  = "2#p0,e,b`"$workspaceDir\boot\etfsboot.com`"" +
                 "#pEF,e,b`"$workspaceDir\efi\microsoft\boot\efisys.bin`""

    Write-Log "Output ISO: $isoPath" -Color Gray
    & "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:$bootArgs" "$workspaceDir" "$isoPath"

    # FIX V2.2+: Capture exit code immediately — cleanup commands overwrite $LASTEXITCODE
    $oscdimgExit = $LASTEXITCODE
    if ($oscdimgExit -ne 0) {
        throw "oscdimg exited with code $oscdimgExit — ISO compilation failed."
    }

    $script:buildSuccess = $true

    # ── Build Summary ──────────────────────────────────────────────────────────
    Write-Progress -Activity 'Tiny10 Builder' -Completed
    $isoSizeGB = [math]::Round((Get-Item $isoPath).Length / 1GB, 2)
    $sha256    = (Get-FileHash -Path $isoPath -Algorithm SHA256).Hash

    Write-Host ''
    Write-Host '════════════════════════════════════════════' -ForegroundColor Green
    Write-Host '             BUILD COMPLETE                 ' -ForegroundColor Green
    Write-Host '════════════════════════════════════════════' -ForegroundColor Green
    Write-Host "  ISO Path     : $isoPath"
    Write-Host "  ISO Size     : ${isoSizeGB} GB"
    Write-Host "  SHA-256      : $sha256"
    Write-Host "  Edition      : $osEdition"
    Write-Host "  Architecture : $architecture"
    Write-Host "  Packages     : $($script:removedPackages.Count) removed"
    Write-Host "  Edge         : $(if ($removeEdge)     { 'Removed' } else { 'Kept' })"
    Write-Host "  OneDrive     : $(if ($removeOneDrive) { 'Removed' } else { 'Kept' })"
    Write-Host '════════════════════════════════════════════' -ForegroundColor Green

} catch {
    Write-Progress -Activity 'Tiny10 Builder' -Completed
    Write-Host ''
    Write-Host "BUILD FAILED: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed

} finally {
    # ── Guaranteed Cleanup ─────────────────────────────────────────────────────
    # Always runs — even on crash or Ctrl+C — so nothing is ever left stranded.

    if ($script:hivesLoaded) {
        Write-Log 'Emergency cleanup: unloading registry hives...' -Color Yellow
        Unload-AllHives
    }

    if ($script:installWimMounted) {
        Write-Log 'Emergency cleanup: discarding install.wim mount...' -Color Yellow
        Dismount-WindowsImage -Path $scratchDir -Discard -ErrorAction SilentlyContinue
    }

    if ($script:bootWimMounted) {
        Write-Log 'Emergency cleanup: discarding boot.wim mount...' -Color Yellow
        Dismount-WindowsImage -Path $scratchDir -Discard -ErrorAction SilentlyContinue
    }

    if (-not $SkipCleanup) {
        Write-Log 'Cleaning up workspace directories...' -Color Gray
        Remove-Item -Path $workspaceDir     -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $scratchDir       -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $localOSCDIMGPath -Force   -ErrorAction SilentlyContinue
        Remove-Item -Path $autounattendPath -Force   -ErrorAction SilentlyContinue
    } else {
        Write-Log "-SkipCleanup set — workspace preserved at: $workspaceDir" -Color Yellow
    }

    if ($DriveLetter) {
        Write-Log 'Ejecting source drive...' -Color Gray
        Get-Volume -DriveLetter $DriveLetter[0] |
            Get-DiskImage | Dismount-DiskImage -ErrorAction SilentlyContinue | Out-Null
    }

    Stop-Transcript
}