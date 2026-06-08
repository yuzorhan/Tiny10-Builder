#Requires -Version 5.1
<#
.SYNOPSIS
    Builds an optimized, lightweight Windows 10 ISO by removing bloatware and telemetry.
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
if (-not $SCRATCH) {
    $ScratchDisk = Split-Path -Qualifier $PSScriptRoot
} else {
    $ScratchDisk = $SCRATCH.Trim().TrimEnd(':').TrimEnd('\') + ':'
}

$workspaceDir     = Join-Path $ScratchDisk 'tiny_workspace'
$scratchDir       = Join-Path $ScratchDisk 'scratchdir'
$logPath          = Join-Path $ScratchDisk 'Output.log'
$autounattendPath = Join-Path $ScratchDisk 'autounattend.xml'
$localOSCDIMGPath = Join-Path $ScratchDisk 'oscdimg.exe'

$DriveLetter    = $null
$removeEdge     = $false
$removeOneDrive = $false
$osEdition      = 'Unknown'

# ── Security Principal ─────────────────────────────────────────────────────────
$adminSID   = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])

# ── Helper Functions ───────────────────────────────────────────────────────────
$script:stepTotal   = 18
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
    Write-Progress -Activity 'Tiny10 Builder' -Status "Step $($script:stepCurrent)/$($script:stepTotal): $Message" -PercentComplete $pct
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

$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
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
Write-Host '           Tiny10 Builder Optimized         ' -ForegroundColor Green
Write-Host '════════════════════════════════════════════' -ForegroundColor Green

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
            Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/yuzorhan/Tiny10-Builder/main/autounattend.xml' -OutFile $autounattendPath
            Write-Log 'autounattend.xml downloaded.' -Color Gray
        } catch {
            Write-Warning "Could not fetch autounattend.xml — continuing without it. $_"
        }
    }

    # ── Step 2: Build Options ──────────────────────────────────────────────────
    Write-Step 'Gathering build options'
    $removeEdge     = if ($KeepEdge)     { $false } else { Read-YesNo 'Remove Microsoft Edge?   (yes/no)' }
    $removeOneDrive = if ($KeepOneDrive) { $false } else { Read-YesNo 'Remove OneDrive?          (yes/no)' }

    # ── Step 3: Source Drive Selection ────────────────────────────────────────
    Write-Step 'Selecting source drive'
    do {
        if (-not $ISO) { $DriveLetter = Read-Host 'Enter the drive letter of your mounted ISO (e.g. D)' } else { $DriveLetter = $ISO }
        $DriveLetter = $DriveLetter.Trim().TrimEnd(':').TrimEnd('\').Trim()
        if ($DriveLetter -match '^[c-zC-Z]$') {
            $DriveLetter += ':'
        } else {
            Write-Host 'Invalid entry.' -ForegroundColor Red
            $ISO = $null
        }
    } while ($DriveLetter -notmatch '^[c-zC-Z]:$')

    $installWim = Join-Path $DriveLetter 'sources\install.wim'
    $installEsd = Join-Path $DriveLetter 'sources\install.esd'
    $targetWim  = Join-Path $workspaceDir 'sources\install.wim'

    if (-not (Test-Path $installWim) -and -not (Test-Path $installEsd)) {
        throw "Cannot find install WIM/ESD files on $DriveLetter"
    }

    # ── Step 4: Disk Space Check ───────────────────────────────────────────────
    Write-Step 'Checking available disk space'
    Assert-FreeSpace -Drive $ScratchDisk -RequiredGB 25

    # ── Step 5: Workspace Initialization ──────────────────────────────────────
    Write-Step 'Initializing build workspace'
    foreach ($dir in $workspaceDir, $scratchDir) {
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $workspaceDir 'sources') | Out-Null
    New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

    # ── Step 6: Copy Source Files ──────────────────────────────────────────────
    Write-Step 'Copying ISO source structure'
    Get-ChildItem -Path $DriveLetter -Recurse -Exclude 'install.wim','install.esd' | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        $relative = $_.FullName.Substring($DriveLetter.Length).TrimStart('\')
        $dest     = Join-Path $workspaceDir $relative
        $destDir  = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        Copy-Item -Path $_.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
    }

    # ── Step 7: Image Extraction ───────────────────────────────────────────────
    Write-Step 'Extracting Windows image'
    $srcPath = if (Test-Path $installWim) { $installWim } else { $installEsd }
    Get-WindowsImage -ImagePath $srcPath
    $index = Read-Host 'Select image index (e.g. 6 for Pro)'
    Export-WindowsImage -SourceImagePath $srcPath -SourceIndex $index -DestinationImagePath $targetWim -CompressionType Maximum

    # ── Step 8: Mount Install Image ────────────────────────────────────────────
    Write-Step 'Mounting Windows image'
    & takeown "/F" $targetWim | Out-Null
    & icacls $targetWim "/grant" "$($adminGroup.Value):(F)" | Out-Null
    Set-ItemProperty -Path $targetWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

    Dismount-AllStaleMounts
    Mount-WindowsImage -ImagePath $targetWim -Index 1 -Path $scratchDir
    $script:installWimMounted = $true

    $wimInfo      = Get-WindowsImage -ImagePath $targetWim -Index 1
    $architecture = if ($wimInfo.Architecture -eq 0) { 'x86' } else { 'amd64' }
    $osEdition    = $wimInfo.ImageName

    # ── Step 9: Bloatware Package Removal ─────────────────────────────────────
    Write-Step 'Removing bloatware packages'
    $packages = & dism "/image:$scratchDir" '/Get-ProvisionedAppxPackages' | ForEach-Object { if ($_ -match 'PackageName : (.*)') { $matches[1] } }

    $packagePrefixes = @('Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection','Microsoft.People','Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps','Microsoft.WindowsSoundRecorder','Microsoft.YourPhone','Microsoft.ZuneMusic','Microsoft.ZuneVideo','microsoft.windowscommunicationsapps','Clipchamp.Clipchamp','Microsoft.Copilot','Microsoft.Windows.Copilot','Microsoft.OutlookForWindows','Microsoft.PowerAutomateDesktop','Microsoft.Wallet','Microsoft.Windows.Teams','MSTeams','Cortana','Microsoft.549981C3F5F10','GamingApp','Xbox')

    foreach ($pkg in ($packages | Where-Object { $p = $_; $packagePrefixes | Where-Object { $p -like "*$_*" } })) {
        & dism "/image:$scratchDir" '/Remove-ProvisionedAppxPackage' "/PackageName:$pkg" | Out-Null
        $script:removedPackages.Add($pkg)
    }

    # ── STEP 10: Stripping Heavy Windows Capabilities ─────────────────────────
    Write-Step 'Stripping unnecessary Windows capabilities'
    $capPrefixes = @('Browser.InternetExplorer', 'MathRecognizer', 'App.StepsRecorder', 'Hello.Face')
    foreach ($cap in (Get-WindowsCapability -Path $scratchDir -ErrorAction SilentlyContinue)) {
        if ($cap.State -eq 'Installed') {
            foreach ($prefix in $capPrefixes) {
                if ($cap.Name -like "$prefix*") {
                    Write-Log "  Removing Capability: $($cap.Name)" -Color DarkYellow
                    Remove-WindowsCapability -Path $scratchDir -Name $cap.Name -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    }

    # ── Step 11: Edge / OneDrive File Removal ─────────────────────────────────
    Write-Step 'Removing optional system components'
    if ($removeEdge) {
        foreach ($p in @("$scratchDir\Program Files (x86)\Microsoft\Edge", "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate", "$scratchDir\Program Files (x86)\Microsoft\EdgeCore")) {
            Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
        }
        $webview = "$scratchDir\Windows\System32\Microsoft-Edge-Webview"
        if (Test-Path $webview) {
            & takeown '/f' $webview '/r' | Out-Null
            & icacls $webview '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
            Remove-Item -Path $webview -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($removeOneDrive) {
        $odBin = "$scratchDir\Windows\System32\OneDriveSetup.exe"
        if (Test-Path $odBin) {
            & takeown "/f" $odBin | Out-Null
            & icacls $odBin "/grant" "$($adminGroup.Value):(F)" | Out-Null
            Remove-Item -Path $odBin -Force -ErrorAction SilentlyContinue
        }
    }

    # ── Step 12: Offline Registry Tweaks ──────────────────────────────────────
    Write-Step 'Applying privacy and system performance tweaks'
    reg load HKLM\zCOMPONENTS "$scratchDir\Windows\System32\config\COMPONENTS" | Out-Null
    reg load HKLM\zDEFAULT    "$scratchDir\Windows\System32\config\default"    | Out-Null
    reg load HKLM\zNTUSER      "$scratchDir\Users\Default\ntuser.dat"           | Out-Null
    reg load HKLM\zSOFTWARE    "$scratchDir\Windows\System32\config\SOFTWARE"   | Out-Null
    reg load HKLM\zSYSTEM      "$scratchDir\Windows\System32\config\SYSTEM"     | Out-Null
    $script:hivesLoaded = $true

    foreach ($hive in 'zDEFAULT','zNTUSER') {
        Set-RegistryValue "HKLM\$hive\Control Panel\UnsupportedHardwareNotificationCache" 'SV1' 'REG_DWORD' '0'
        Set-RegistryValue "HKLM\$hive\Control Panel\UnsupportedHardwareNotificationCache" 'SV2' 'REG_DWORD' '0'
    }

    $cdm = 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Set-RegistryValue $cdm 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue $cdm 'PreInstalledAppsEnabled'    'REG_DWORD' '0'
    Set-RegistryValue $cdm 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 'REG_DWORD' '0'

    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'

    $labConfig = 'HKLM\zSYSTEM\Setup\LabConfig'
    foreach ($key in 'BypassCPUCheck','BypassRAMCheck','BypassSecureBootCheck','BypassStorageCheck','BypassTPMCheck') {
        Set-RegistryValue $labConfig $key 'REG_DWORD' '1'
    }
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

    foreach ($svc in 'DiagTrack','dmwappushservice','WSearch','WerSvc') {
        Set-RegistryValue "HKLM\zSYSTEM\ControlSet001\Services\$svc" 'Start' 'REG_DWORD' '4'
    }

    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'

    if ($removeEdge) {
        Remove-RegistryValue 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
        Remove-RegistryValue 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update'
    }
    if ($removeOneDrive) {
        Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 'REG_DWORD' '1'
    }

    Unload-AllHives
    $script:hivesLoaded = $false

    # ── Step 13: Scheduled Task Removal ───────────────────────────────────────
    Write-Step 'Removing diagnostic scheduled tasks'
    $tasks = "$scratchDir\Windows\System32\Tasks\Microsoft\Windows"
    Remove-Item "$tasks\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
    Remove-Item "$tasks\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$tasks\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
    Remove-Item "$tasks\Windows Error Reporting\QueueReporting"    -Force -ErrorAction SilentlyContinue

    # ── Step 14: Component Cleanup & Dismount Install Image ───────────────────
    Write-Step 'Running component cleanup and saving install image'
    & dism.exe /Image:"$scratchDir" /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null
    Dismount-WindowsImage -Path $scratchDir -Save
    $script:installWimMounted = $false

    # ── Step 15: Boot Environment Patching ────────────────────────────────────
    Write-Step 'Patching boot environment (boot.wim)'
    $bootWimPath = Join-Path $workspaceDir 'sources\boot.wim'
    & takeown "/F" $bootWimPath | Out-Null
    & icacls $bootWimPath "/grant" "$($adminGroup.Value):(F)" | Out-Null
    Set-ItemProperty -Path $bootWimPath -Name IsReadOnly -Value $false

    Dismount-AllStaleMounts
    Mount-WindowsImage -ImagePath $bootWimPath -Index 2 -Path $scratchDir
    $script:bootWimMounted = $true

    reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null
    foreach ($key in 'BypassCPUCheck','BypassRAMCheck','BypassSecureBootCheck','BypassStorageCheck','BypassTPMCheck') {
        Set-RegistryValue $labConfig $key 'REG_DWORD' '1'
    }
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
    reg unload HKLM\zSYSTEM | Out-Null

    Dismount-WindowsImage -Path $scratchDir -Save
    $script:bootWimMounted = $false

    # ── Step 16: Export to Compact ESD ────────────────────────────────────────
    Write-Step 'Exporting to highly compressed solid ESD format'
    $finalEsd = Join-Path $workspaceDir 'sources\install.esd'
    & dism.exe /Export-Image /SourceImageFile:$targetWim /SourceIndex:1 /DestinationImageFile:$finalEsd /Compress:recovery
    Remove-Item -Path $targetWim -Force -ErrorAction SilentlyContinue

    # ── Step 17: Inject Answer File ────────────────────────────────────────────
    Write-Step 'Injecting autounattend.xml'
    if (Test-Path $autounattendPath) { Copy-Item -Path $autounattendPath -Destination (Join-Path $workspaceDir 'autounattend.xml') -Force }

    # ── Step 18: Compile ISO ───────────────────────────────────────────────────
    Write-Step 'Compiling final bootable ISO image'
    $ADKPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$architecture\Oscdimg"
    if (Test-Path $ADKPath) {
        $OSCDIMG = Join-Path $ADKPath 'oscdimg.exe'
    } else {
        if (-not (Test-Path $localOSCDIMGPath)) {
            Invoke-WebRequest -Uri 'https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe' -OutFile $localOSCDIMGPath
        }
        $OSCDIMG = $localOSCDIMGPath
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $isoPath   = Join-Path $ScratchDisk "Tiny10_$timestamp.iso"
    $bootArgs  = "2#p0,e,b`"$workspaceDir\boot\etfsboot.com`"#" + "pEF,e,b`"$workspaceDir\efi\microsoft\boot\efisys.bin`""

    & "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:$bootArgs" "$workspaceDir" "$isoPath"

    if ($LASTEXITCODE -ne 0) { throw "oscdimg compilation failed." }
    $script:buildSuccess = $true

    # ── Build Summary ──────────────────────────────────────────────────────────
    Write-Progress -Activity 'Tiny10 Builder' -Completed
    Write-Host "`n[SUCCESS] Custom lightweight ISO built at: $isoPath" -ForegroundColor Green

} catch {
    Write-Progress -Activity 'Tiny10 Builder' -Completed
    Write-Host "`n[ERROR] Build broken: $_" -ForegroundColor Red
} finally {
    if ($script:hivesLoaded) { Unload-AllHives }
    if ($script:installWimMounted -or $script:bootWimMounted) { Dismount-WindowsImage -Path $scratchDir -Discard -ErrorAction SilentlyContinue }
    if (-not $SkipCleanup) { Remove-Item -Path $workspaceDir, $scratchDir, $localOSCDIMGPath -Recurse -Force -ErrorAction SilentlyContinue }
    if ($DriveLetter) { Get-Volume -DriveLetter $DriveLetter[0] | Get-DiskImage | Dismount-DiskImage -ErrorAction SilentlyContinue | Out-Null }
    Stop-Transcript
}