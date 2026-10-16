#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a customized Windows 10 ISO from a mounted Windows installation ISO.

.DESCRIPTION
    Parser and reliability fixes:
      - ASCII-only source text to avoid encoding/mojibake parser errors.
      - Safe variable interpolation where a colon follows a variable.
      - Supports Windows PowerShell 5.1 and PowerShell 7 syntax.
      - Validates source image, boot image, and exported image indexes.
      - Copies the source with Robocopy and checks its exit code.
      - Discards stale mounts before deleting the workspace.
      - Tracks loaded offline registry hives and unloads only those hives.
      - Handles DISM architecture values whether numeric or textual.
      - Does not download oscdimg.exe from a hard-coded URL.
      - Returns a non-zero process exit code if the build fails.

    Revision 2 fixes:
      - Native commands are wrapped so stderr output cannot trigger a
        terminating NativeCommandError under Windows PowerShell 5.1.
      - ISO files are mounted via Get-Volume (Get-Disk does not work for ISOs).
      - Removed script-level -WhatIf support (it was only partly honored).
      - Elevation: relative -ISO paths resolved first, UAC cancel handled,
        exit code propagated, window stays open until Enter is pressed.
      - Edge / OneDrive files are taken over before deletion.
      - TailoredExperiences setting moved to the per-user hive.
      - Safer default scratch drive detection and validation.

.NOTES
    Run this on Windows as Administrator. Install the Windows ADK Deployment
    Tools so oscdimg.exe is available. Use a genuine Windows 10 ISO mounted in
    Windows. At least 25 GB of free space is recommended on the scratch drive.
#>

[CmdletBinding()]
param (
    # A mounted ISO drive letter (for example D:) or a path to an ISO file.
    [string]$ISO,
    # Scratch drive letter only (for example E or E:). Defaults to the script drive.
    [string]$SCRATCH,
    [switch]$KeepEdge,
    [switch]$KeepOneDrive,
    [switch]$SkipCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Path initialization
# -----------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($SCRATCH)) {
    $scratchInput = $SCRATCH.Trim()
    if ($scratchInput -match '^([A-Za-z]):?\\?$') {
        $ScratchDisk = ('{0}:' -f $Matches[1].ToUpperInvariant())
    }
    else {
        throw 'SCRATCH must be a drive letter only, such as E or E:.'
    }
}
else {
    $ScratchDisk = $null
    try { $ScratchDisk = Split-Path -Qualifier $PSScriptRoot -ErrorAction Stop } catch { $ScratchDisk = $null }
    if ([string]::IsNullOrWhiteSpace($ScratchDisk)) {
        $ScratchDisk = $env:SystemDrive
    }
}

if ([string]::IsNullOrWhiteSpace($ScratchDisk) -or $ScratchDisk -notmatch '^[A-Za-z]:$') {
    throw 'Could not determine a local scratch drive. Use -SCRATCH E to select one.'
}
if (-not (Test-Path -LiteralPath ($ScratchDisk + '\'))) {
    throw ('Scratch drive {0} does not exist.' -f $ScratchDisk)
}

$ScratchRoot      = $ScratchDisk + '\'
$workspaceDir     = Join-Path $ScratchRoot 'tiny_workspace'
$scratchDir       = Join-Path $ScratchRoot 'scratchdir'
$logPath          = Join-Path $ScratchRoot 'Output.log'
$autounattendPath = Join-Path $ScratchRoot 'autounattend.xml'

$DriveLetter       = $null
$removeEdge        = $false
$removeOneDrive    = $false
$osEdition         = 'Unknown'
$architecture      = $null
$bootIndex         = $null
$finalInstallIndex = $null
$OSCDIMG           = $null
$isoPath           = $null
$sourceDiskImage   = $null

$adminSID   = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])

$script:stepTotal         = 18
$script:stepCurrent       = 0
$script:installWimMounted = $false
$script:bootWimMounted    = $false
$script:removedPackages   = [System.Collections.Generic.List[string]]::new()
$script:loadedHives       = [System.Collections.Generic.List[string]]::new()
$script:buildSuccess      = $false
$script:transcriptStarted = $false

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ConsoleColor]$Color = 'White'
    )
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host ('[{0}] {1}' -f $ts, $Message) -ForegroundColor $Color
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)

    $script:stepCurrent++
    $pct = [int](($script:stepCurrent / $script:stepTotal) * 100)
    Write-Progress -Activity 'Tiny10 Builder' `
        -Status ('Step {0}/{1}: {2}' -f $script:stepCurrent, $script:stepTotal, $Message) `
        -PercentComplete $pct
    Write-Log ('--- Step {0}/{1}: {2} ---' -f $script:stepCurrent, $script:stepTotal, $Message) -Color Cyan
}

function Invoke-Native {
    # Runs a native executable and returns its exit code and output lines.
    # Under Windows PowerShell 5.1, "2>&1" turns stderr text into error records,
    # and $ErrorActionPreference = 'Stop' then throws on any stderr output
    # (for example "reg delete" on a missing key). Relax the preference here.
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedPreference
    }

    return [pscustomobject]@{
        ExitCode = $code
        Output   = $lines
    }
}

function Get-NativeTail {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [int]$Count = 6
    )
    return ((@($Result.Output | Select-Object -Last $Count)) -join ' ')
}

function Grant-AdminAccess {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Recurse
    )
    $takeownArgs = @('/F', $Path)
    $icaclsArgs  = @($Path, '/grant', ('{0}:(F)' -f $adminGroup.Value))
    if ($Recurse) {
        $takeownArgs += @('/R', '/D', 'Y')
        $icaclsArgs  += @('/T', '/C')
    }
    [void](Invoke-Native -FilePath 'takeown.exe' -Arguments $takeownArgs)
    [void](Invoke-Native -FilePath 'icacls.exe' -Arguments $icaclsArgs)
}

function Remove-OwnedItem {
    # Takes ownership of a protected file or folder inside the mounted image, then deletes it.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Recurse
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Grant-AdminAccess -Path $Path -Recurse:$Recurse
    try {
        if ($Recurse) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        else {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
    }
    catch {
        Write-Warning ('Could not completely remove {0}: {1}' -f $Path, $_.Exception.Message)
    }
}

function Set-RegistryValue {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('REG_SZ','REG_EXPAND_SZ','REG_DWORD','REG_QWORD','REG_BINARY','REG_MULTI_SZ')][string]$Type,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($PSCmdlet.ShouldProcess(('{0}\{1}' -f $Path, $Name), 'Set registry value')) {
        $result = Invoke-Native -FilePath 'reg.exe' -Arguments @('add', $Path, '/v', $Name, '/t', $Type, '/d', $Value, '/f')
        if ($result.ExitCode -ne 0) {
            Write-Warning ('Registry set returned exit code {0}: {1}\{2}' -f $result.ExitCode, $Path, $Name)
        }
    }
}

function Remove-RegistryKey {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($PSCmdlet.ShouldProcess($Path, 'Delete registry key')) {
        $result = Invoke-Native -FilePath 'reg.exe' -Arguments @('delete', $Path, '/f')
        if ($result.ExitCode -ne 0) {
            Write-Warning ('Registry delete returned exit code {0} (key may not exist): {1}' -f $result.ExitCode, $Path)
        }
    }
}

function Read-YesNo {
    param([Parameter(Mandatory = $true)][string]$Prompt)
    do {
        $answer = (Read-Host $Prompt).Trim().ToLowerInvariant()
        if ($answer -notin @('yes','y','no','n')) {
            Write-Host 'Please enter yes/no (or y/n).' -ForegroundColor Red
        }
    } while ($answer -notin @('yes','y','no','n'))
    return ($answer -in @('yes','y'))
}

function Assert-FreeSpace {
    param(
        [Parameter(Mandatory = $true)][string]$Drive,
        [Parameter(Mandatory = $true)][int]$RequiredGB
    )
    $letter = $Drive.Substring(0, 1)
    $driveInfo = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    if (-not $driveInfo -or $null -eq $driveInfo.Free) {
        throw ('Could not determine free space on {0}.' -f $Drive)
    }
    $freeGB = [math]::Round(($driveInfo.Free / 1GB), 1)
    if ($driveInfo.Free -lt ($RequiredGB * 1GB)) {
        throw ('Insufficient disk space on {0}. Need {1} GB; available: {2} GB.' -f $Drive, $RequiredGB, $freeGB)
    }
    Write-Log ('Disk space OK: {0} GB free on {1}.' -f $freeGB, $Drive) -Color Gray
}

function Unload-RegistryHive {
    param([Parameter(Mandatory = $true)][string]$HiveName)
    if ($script:loadedHives.Contains($HiveName)) {
        $result = Invoke-Native -FilePath 'reg.exe' -Arguments @('unload', ('HKLM\{0}' -f $HiveName))
        if ($result.ExitCode -eq 0) {
            [void]$script:loadedHives.Remove($HiveName)
        }
        else {
            Write-Warning ('Could not unload registry hive HKLM\{0}. Exit code: {1}' -f $HiveName, $result.ExitCode)
        }
    }
}

function Unload-AllHives {
    # Unload in reverse load order; do not touch hives that this script did not load.
    $loadedCopy = @($script:loadedHives.ToArray())
    [array]::Reverse($loadedCopy)
    foreach ($hiveName in $loadedCopy) {
        Unload-RegistryHive -HiveName $hiveName
    }
}

function Load-RegistryHive {
    param(
        [Parameter(Mandatory = $true)][string]$HiveName,
        [Parameter(Mandatory = $true)][string]$HiveFile
    )
    if (-not (Test-Path -LiteralPath $HiveFile -PathType Leaf)) {
        throw ('Registry hive file was not found: {0}' -f $HiveFile)
    }
    if ($script:loadedHives.Contains($HiveName)) {
        throw ('Registry hive HKLM\{0} is already tracked as loaded.' -f $HiveName)
    }

    $result = Invoke-Native -FilePath 'reg.exe' -Arguments @('load', ('HKLM\{0}' -f $HiveName), $HiveFile)
    if ($result.ExitCode -ne 0) {
        throw ('Failed to load registry hive HKLM\{0} from {1}. Exit code: {2}' -f $HiveName, $HiveFile, $result.ExitCode)
    }
    $script:loadedHives.Add($HiveName)
}

function Dismount-ScratchMount {
    $mountedImages = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)
    foreach ($mount in $mountedImages) {
        if ($mount.Path -and ($mount.Path.TrimEnd('\') -ieq $scratchDir.TrimEnd('\'))) {
            Write-Log ('Discarding existing image mount at: {0}' -f $mount.Path) -Color Yellow
            Dismount-WindowsImage -Path $mount.Path -Discard -ErrorAction Stop | Out-Null
        }
    }

    $remaining = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and ($_.Path.TrimEnd('\') -ieq $scratchDir.TrimEnd('\'))
    })
    if ($remaining.Count -gt 0) {
        throw ('Could not clear existing image mount at {0}.' -f $scratchDir)
    }
}

function Select-ImageIndex {
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][string]$Prompt
    )

    $images = @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop)
    if ($images.Count -eq 0) {
        throw ('No Windows images were found in: {0}' -f $ImagePath)
    }

    Write-Log ('Available images in {0}:' -f $ImagePath) -Color Gray
    $tableText = $images | Format-Table ImageIndex, ImageName, ImageDescription -AutoSize | Out-String
    Write-Host $tableText

    if ($images.Count -eq 1) {
        $onlyIndex = [int]$images[0].ImageIndex
        Write-Log ('Only one image is present. Automatically selecting index {0}.' -f $onlyIndex) -Color Green
        return $onlyIndex
    }

    do {
        $inputIndex = Read-Host $Prompt
        $selectedIndex = 0
        if (-not [int]::TryParse($inputIndex, [ref]$selectedIndex)) {
            Write-Host 'Invalid index. Enter a numeric index shown in the list.' -ForegroundColor Red
            continue
        }
        $match = @($images | Where-Object { [int]$_.ImageIndex -eq $selectedIndex })
        if ($match.Count -eq 0) {
            Write-Host ('Index {0} does not exist in this image.' -f $selectedIndex) -ForegroundColor Red
            $selectedIndex = 0
        }
    } while ($selectedIndex -eq 0)

    Write-Log ('Selected image index: {0}' -f $selectedIndex) -Color Green
    return [int]$selectedIndex
}

function Resolve-Architecture {
    param([Parameter(Mandatory = $true)]$ArchitectureValue)
    $archText = ([string]$ArchitectureValue).Trim().ToLowerInvariant()
    switch -Regex ($archText) {
        '^(0|x86|i386)$' { return 'x86' }
        '^(9|amd64|x64)$' { return 'amd64' }
        '^(12|arm64)$' { throw 'ARM64 images are not supported by this answer-file generator.' }
        default { throw ('Unsupported or unrecognized Windows image architecture value: {0}' -f $ArchitectureValue) }
    }
}

function Write-FixedAutounattend {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('x86','amd64')][string]$Architecture,
        [Parameter(Mandatory = $true)][ValidateRange(1, 999)][int]$InstallIndex
    )

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Setup" processorArchitecture="$Architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DynamicUpdate>
        <WillShowUI>OnError</WillShowUI>
        <Enable>false</Enable>
      </DynamicUpdate>
      <ImageInstall>
        <OSImage>
          <Compact>true</Compact>
          <WillShowUI>OnError</WillShowUI>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/INDEX</Key>
              <Value>$InstallIndex</Value>
            </MetaData>
          </InstallFrom>
        </OSImage>
      </ImageInstall>
      <UserData>
        <ProductKey>
          <Key></Key>
          <WillShowUI>OnError</WillShowUI>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Shell-Setup" processorArchitecture="$Architecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideLocalAccountScreen>false</HideLocalAccountScreen>
        <HideEULAPage>true</HideEULAPage>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
    </component>
  </settings>
</unattend>
"@

    # Write UTF-8 without a BOM. The declaration above matches the encoding.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $xml, $utf8NoBom)
    Write-Log 'Generated autounattend.xml locally.' -Color Gray
}

function ConvertTo-PSLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

# -----------------------------------------------------------------------------
# Administrator elevation. Use an encoded command to preserve paths containing
# spaces or apostrophes when relaunching Windows PowerShell 5.1.
# -----------------------------------------------------------------------------
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Host 'Cannot relaunch as Administrator because the script path is unknown. Run this saved .ps1 file from an elevated console.' -ForegroundColor Red
        exit 1
    }

    Write-Host 'Re-launching as Administrator...' -ForegroundColor Cyan

    # The elevated process starts in System32, so relative ISO paths must be resolved first.
    $isoForChild = $ISO
    if (-not [string]::IsNullOrWhiteSpace($ISO) -and (Test-Path -LiteralPath $ISO -PathType Leaf)) {
        $isoForChild = (Resolve-Path -LiteralPath $ISO).Path
    }

    $childCommand = '& ' + (ConvertTo-PSLiteral -Value $PSCommandPath)
    if (-not [string]::IsNullOrWhiteSpace($isoForChild)) {
        $childCommand += ' -ISO ' + (ConvertTo-PSLiteral -Value $isoForChild)
    }
    if (-not [string]::IsNullOrWhiteSpace($SCRATCH)) {
        $childCommand += ' -SCRATCH ' + (ConvertTo-PSLiteral -Value $SCRATCH)
    }
    if ($KeepEdge) { $childCommand += ' -KeepEdge' }
    if ($KeepOneDrive) { $childCommand += ' -KeepOneDrive' }
    if ($SkipCleanup) { $childCommand += ' -SkipCleanup' }

    # Keep the elevated window open so the result can be read, then pass the exit code back.
    $childCommand += '; $code = $LASTEXITCODE; Read-Host "Press Enter to close this window" | Out-Null; exit $code'

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        $childProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encodedCommand) -Verb RunAs -Wait -PassThru -ErrorAction Stop
    }
    catch {
        Write-Host ('Could not start an elevated PowerShell: {0}' -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    exit $childProcess.ExitCode
}

# -----------------------------------------------------------------------------
# Main build
# -----------------------------------------------------------------------------
try {
    Start-Transcript -Path $logPath -Force | Out-Null
    $script:transcriptStarted = $true

    try {
        Import-Module Dism -ErrorAction Stop
    }
    catch {
        throw ('Could not load the DISM PowerShell module. Run this on Windows with DISM available. Details: {0}' -f $_.Exception.Message)
    }

    $Host.UI.RawUI.WindowTitle = 'Tiny10 Builder'
    Clear-Host
    Write-Host '============================================' -ForegroundColor Green
    Write-Host '       Tiny10 Builder Optimized (Fixed)     ' -ForegroundColor Green
    Write-Host '============================================' -ForegroundColor Green

    # Step 1
    Write-Step 'Preparing answer file configuration'
    Write-Log 'The answer file is generated locally; no old XML is downloaded.' -Color Gray

    # Step 2
    Write-Step 'Gathering build options'
    $removeEdge = if ($KeepEdge) { $false } else { Read-YesNo 'Remove Microsoft Edge files? (yes/no)' }
    $removeOneDrive = if ($KeepOneDrive) { $false } else { Read-YesNo 'Remove OneDrive setup? (yes/no)' }

    # Step 3
    Write-Step 'Selecting source drive'
    if (-not [string]::IsNullOrWhiteSpace($ISO) -and (Test-Path -LiteralPath $ISO -PathType Leaf)) {
        if ([IO.Path]::GetExtension($ISO) -ine '.iso') {
            throw ('-ISO points to a file that is not an ISO: {0}' -f $ISO)
        }
        $isoFullPath = (Resolve-Path -LiteralPath $ISO).Path
        $sourceDiskImage = Mount-DiskImage -ImagePath $isoFullPath -PassThru -ErrorAction Stop

        # An ISO mounts as a CD-ROM volume, not a disk, so Get-Disk does not apply. Use Get-Volume.
        $mountedVolume = $null
        for ($attempt = 0; ($attempt -lt 10) -and (-not $mountedVolume); $attempt++) {
            $mountedVolume = @($sourceDiskImage | Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }) | Select-Object -First 1
            if (-not $mountedVolume) {
                Start-Sleep -Seconds 1
            }
        }
        if (-not $mountedVolume) {
            throw ('The ISO was mounted but no drive letter was assigned: {0}' -f $ISO)
        }
        $DriveLetter = ('{0}:' -f $mountedVolume.DriveLetter)
        Write-Log ('Mounted ISO file to {0}.' -f $DriveLetter) -Color Gray
    }
    else {
        do {
            if ([string]::IsNullOrWhiteSpace($ISO)) {
                $candidate = Read-Host 'Enter the drive letter of your mounted Windows ISO (e.g. D)'
            }
            else {
                $candidate = $ISO
            }
            $candidate = $candidate.Trim().TrimEnd('\')
            if ($candidate -match '^([C-Zc-z]):?$') {
                $DriveLetter = ('{0}:' -f $Matches[1].ToUpperInvariant())
            }
            else {
                Write-Host 'Invalid entry. Enter a mounted ISO drive letter such as D or D:.' -ForegroundColor Red
                $ISO = $null
                $DriveLetter = $null
            }
        } while (-not $DriveLetter)
    }

    if (-not (Test-Path -LiteralPath ($DriveLetter + '\'))) {
        throw ('Drive {0} could not be accessed.' -f $DriveLetter)
    }

    $sourceRoot  = $DriveLetter + '\'
    $installWim  = Join-Path $sourceRoot 'sources\install.wim'
    $installEsd  = Join-Path $sourceRoot 'sources\install.esd'
    $installSwm  = Join-Path $sourceRoot 'sources\install.swm'
    $targetWim   = Join-Path $workspaceDir 'sources\install.wim'
    $bootWimPath = Join-Path $workspaceDir 'sources\boot.wim'

    if ((Test-Path -LiteralPath $installSwm) -and -not (Test-Path -LiteralPath $installWim) -and -not (Test-Path -LiteralPath $installEsd)) {
        throw 'This ISO uses split install.swm files. This script supports install.wim or install.esd sources only.'
    }
    if (-not (Test-Path -LiteralPath $installWim) -and -not (Test-Path -LiteralPath $installEsd)) {
        throw ('Cannot find sources\install.wim or sources\install.esd on {0}.' -f $DriveLetter)
    }
    $srcPath = if (Test-Path -LiteralPath $installWim) { $installWim } else { $installEsd }
    Write-Log ('Source image: {0}' -f $srcPath) -Color Gray

    # Step 4
    Write-Step 'Checking available disk space'
    Assert-FreeSpace -Drive $ScratchDisk -RequiredGB 25

    # Step 5
    Write-Step 'Initializing build workspace'
    # Clear an old mount before removing its directory.
    Dismount-ScratchMount
    foreach ($dir in @($workspaceDir, $scratchDir)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
        }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $workspaceDir 'sources') | Out-Null
    New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null

    # Step 6
    Write-Step 'Copying ISO source structure'
    # Robocopy exit codes 0-7 are non-fatal; 8 or higher indicates failure.
    $copyResult = Invoke-Native -FilePath 'robocopy.exe' -Arguments @(
        $sourceRoot, $workspaceDir, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/XF', 'install.wim', 'install.esd', 'install.swm'
    )
    if ($copyResult.ExitCode -ge 8) {
        throw ('Robocopy failed with exit code {0}. Check source media and destination disk.' -f $copyResult.ExitCode)
    }
    if (-not (Test-Path -LiteralPath $bootWimPath -PathType Leaf)) {
        throw 'boot.wim was not copied to the workspace.'
    }
    foreach ($requiredRelativePath in @('boot\etfsboot.com','efi\microsoft\boot\efisys.bin','setup.exe')) {
        $requiredPath = Join-Path $workspaceDir $requiredRelativePath
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw ('Required Windows setup file was not copied: {0}' -f $requiredRelativePath)
        }
    }

    # Step 7
    Write-Step 'Selecting and extracting Windows image'
    $sourceIndex = Select-ImageIndex -ImagePath $srcPath -Prompt 'Select the install image index to build'
    if (Test-Path -LiteralPath $targetWim) {
        Remove-Item -LiteralPath $targetWim -Force
    }
    Write-Log 'Exporting the selected image to a WIM. This can take several minutes...' -Color Gray
    $exportResult = Invoke-Native -FilePath 'dism.exe' -Arguments @(
        '/Export-Image',
        ('/SourceImageFile:{0}' -f $srcPath),
        ('/SourceIndex:{0}' -f $sourceIndex),
        ('/DestinationImageFile:{0}' -f $targetWim),
        '/Compress:max',
        '/CheckIntegrity'
    )
    if ($exportResult.ExitCode -ne 0) {
        throw ('DISM WIM export failed with exit code {0}. Output: {1}' -f $exportResult.ExitCode, (Get-NativeTail -Result $exportResult))
    }
    if (-not (Test-Path -LiteralPath $targetWim -PathType Leaf)) {
        throw 'DISM reported success, but the exported target WIM was not created.'
    }

    # Step 8
    Write-Step 'Mounting Windows image'
    Grant-AdminAccess -Path $targetWim
    try { (Get-Item -LiteralPath $targetWim -Force).IsReadOnly = $false } catch { }
    Dismount-ScratchMount

    $targetImages = @(Get-WindowsImage -ImagePath $targetWim -ErrorAction Stop)
    if ($targetImages.Count -ne 1) {
        throw ('Expected exactly one image in the exported target WIM, found {0}.' -f $targetImages.Count)
    }
    $targetIndex = [int]$targetImages[0].ImageIndex
    Write-Log ('Exported target WIM index: {0}' -f $targetIndex) -Color Gray

    Mount-WindowsImage -ImagePath $targetWim -Index $targetIndex -Path $scratchDir -ErrorAction Stop | Out-Null
    $script:installWimMounted = $true

    $wimInfo = Get-WindowsImage -ImagePath $targetWim -Index $targetIndex -ErrorAction Stop
    $architecture = Resolve-Architecture -ArchitectureValue $wimInfo.Architecture
    $osEdition = [string]$wimInfo.ImageName
    Write-Log ('Selected edition: {0}' -f $osEdition) -Color Gray
    Write-Log ('Architecture: {0}' -f $architecture) -Color Gray

    # Step 9
    Write-Step 'Removing bloatware packages'
    $appxResult = Invoke-Native -FilePath 'dism.exe' -Arguments @(('/Image:{0}' -f $scratchDir), '/Get-ProvisionedAppxPackages')
    if ($appxResult.ExitCode -ne 0) {
        throw ('Could not enumerate provisioned Appx packages. DISM exit code: {0}' -f $appxResult.ExitCode)
    }
    $packages = @(
        foreach ($line in $appxResult.Output) {
            if ([string]$line -match '^\s*PackageName\s*:\s*(.+?)\s*$') {
                $Matches[1].Trim()
            }
        }
    )

    # Package identity names to remove. Matching is exact to avoid removing
    # unrelated packages that happen to begin with the same text.
    $packagePrefixes = @(
        'AppUp.IntelManagementandSecurityStatus',
        'Clipchamp.Clipchamp',
        'DolbyLaboratories.DolbyAccess',
        'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
        'Microsoft.BingNews',
        'Microsoft.BingSearch',
        'Microsoft.BingWeather',
        'Microsoft.Copilot',
        'Microsoft.Windows.CrossDevice',
        'Microsoft.GamingApp',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.Microsoft3DViewer',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes',
        'Microsoft.MixedReality.Portal',
        'Microsoft.MSPaint',
        'Microsoft.Office.OneNote',
        'Microsoft.OfficePushNotificationUtility',
        'Microsoft.OutlookForWindows',
        'Microsoft.Paint',
        'Microsoft.People',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.SkypeApp',
        'Microsoft.StartExperiencesApp',
        'Microsoft.Todos',
        'Microsoft.Wallet',
        'Microsoft.Windows.DevHome',
        'Microsoft.Windows.Copilot',
        'Microsoft.Windows.Teams',
        'Microsoft.WindowsAlarms',
        'Microsoft.WindowsCamera',
        'microsoft.windowscommunicationsapps',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsMaps',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.WindowsTerminal',
        'Microsoft.Xbox.TCUI',
        'Microsoft.XboxApp',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.YourPhone',
        'Microsoft.ZuneMusic',
        'Microsoft.ZuneVideo',
        'MicrosoftCorporationII.MicrosoftFamily',
        'MicrosoftCorporationII.QuickAssist',
        'MSTeams',
        'MicrosoftTeams',
        'Microsoft.549981C3F5F10'
    )

    if ($packages.Count -eq 0) {
        Write-Log 'No provisioned Appx packages were returned by DISM.' -Color Yellow
    }
    else {
        foreach ($pkg in $packages) {
            # The Appx package identity name is the part before the first underscore.
            $packageName = ($pkg -split '_', 2)[0]
            if ($packagePrefixes -icontains $packageName) {
                Write-Log ('Removing provisioned package: {0}' -f $pkg) -Color DarkYellow
                $removeResult = Invoke-Native -FilePath 'dism.exe' -Arguments @(('/Image:{0}' -f $scratchDir), '/Remove-ProvisionedAppxPackage', ('/PackageName:{0}' -f $pkg))
                if ($removeResult.ExitCode -eq 0) {
                    $script:removedPackages.Add($pkg)
                }
                else {
                    Write-Warning ('Failed to remove package {0}. DISM exit code: {1}' -f $pkg, $removeResult.ExitCode)
                }
            }
        }
    }
    Write-Log ('Provisioned packages removed successfully: {0}' -f $script:removedPackages.Count) -Color Green

    # Step 10
    Write-Step 'Stripping selected Windows capabilities'
    $capPrefixes = @('Browser.InternetExplorer','MathRecognizer','App.StepsRecorder','Hello.Face')
    foreach ($capability in @(Get-WindowsCapability -Path $scratchDir -ErrorAction Stop)) {
        if ($capability.State -eq 'Installed') {
            foreach ($prefix in $capPrefixes) {
                if ($capability.Name -like ($prefix + '*')) {
                    Write-Log ('Removing capability: {0}' -f $capability.Name) -Color DarkYellow
                    Remove-WindowsCapability -Path $scratchDir -Name $capability.Name -ErrorAction Continue | Out-Null
                    break
                }
            }
        }
    }

    # Step 11
    Write-Step 'Removing optional system components'
    if ($removeEdge) {
        # These folders are owned by TrustedInstaller; take ownership before deleting.
        foreach ($edgePath in @(
            (Join-Path $scratchDir 'Program Files (x86)\Microsoft\Edge'),
            (Join-Path $scratchDir 'Program Files (x86)\Microsoft\EdgeUpdate'),
            (Join-Path $scratchDir 'Program Files (x86)\Microsoft\EdgeCore'),
            (Join-Path $scratchDir 'Program Files (x86)\Microsoft\EdgeWebView'),
            (Join-Path $scratchDir 'Windows\System32\Microsoft-Edge-Webview')
        )) {
            Remove-OwnedItem -Path $edgePath -Recurse
        }
    }
    if ($removeOneDrive) {
        foreach ($oneDriveSetup in @(
            (Join-Path $scratchDir 'Windows\System32\OneDriveSetup.exe'),
            (Join-Path $scratchDir 'Windows\SysWOW64\OneDriveSetup.exe')
        )) {
            Remove-OwnedItem -Path $oneDriveSetup
        }
    }

    # Step 12
    Write-Step 'Applying privacy and system performance tweaks'
    Load-RegistryHive -HiveName 'zDEFAULT'  -HiveFile (Join-Path $scratchDir 'Windows\System32\config\default')
    Load-RegistryHive -HiveName 'zNTUSER'   -HiveFile (Join-Path $scratchDir 'Users\Default\ntuser.dat')
    Load-RegistryHive -HiveName 'zSOFTWARE' -HiveFile (Join-Path $scratchDir 'Windows\System32\config\SOFTWARE')
    Load-RegistryHive -HiveName 'zSYSTEM'   -HiveFile (Join-Path $scratchDir 'Windows\System32\config\SYSTEM')

    foreach ($hive in @('zDEFAULT','zNTUSER')) {
        Set-RegistryValue -Path ('HKLM\{0}\Control Panel\UnsupportedHardwareNotificationCache' -f $hive) -Name 'SV1' -Type REG_DWORD -Value '0'
        Set-RegistryValue -Path ('HKLM\{0}\Control Panel\UnsupportedHardwareNotificationCache' -f $hive) -Name 'SV2' -Type REG_DWORD -Value '0'
    }

    $cdm = 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Set-RegistryValue -Path $cdm -Name 'OemPreInstalledAppsEnabled' -Type REG_DWORD -Value '0'
    Set-RegistryValue -Path $cdm -Name 'PreInstalledAppsEnabled' -Type REG_DWORD -Value '0'
    Set-RegistryValue -Path $cdm -Name 'SilentInstalledAppsEnabled' -Type REG_DWORD -Value '0'
    Set-RegistryValue -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Type REG_DWORD -Value '1'
    Set-RegistryValue -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Type REG_DWORD -Value '0'
    Set-RegistryValue -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'DisableWebSearch' -Type REG_DWORD -Value '1'
    Set-RegistryValue -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'ConnectedSearchUseWeb' -Type REG_DWORD -Value '0'
    Set-RegistryValue -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'AllowCortana' -Type REG_DWORD -Value '0'
    # This is a per-user setting, so it belongs in the default user hive, not HKLM\SOFTWARE.
    Set-RegistryValue -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Type REG_DWORD -Value '0'
    Set-RegistryValue -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Type REG_DWORD -Value '0'

    $labConfig = 'HKLM\zSYSTEM\Setup\LabConfig'
    foreach ($valueName in @('BypassCPUCheck','BypassRAMCheck','BypassSecureBootCheck','BypassStorageCheck','BypassTPMCheck')) {
        Set-RegistryValue -Path $labConfig -Name $valueName -Type REG_DWORD -Value '1'
    }
    Set-RegistryValue -Path 'HKLM\zSYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Type REG_DWORD -Value '1'

    # Resolve the active control set instead of assuming ControlSet001.
    $selectResult = Invoke-Native -FilePath 'reg.exe' -Arguments @('query', 'HKLM\zSYSTEM\Select', '/v', 'Current')
    $controlSet = 'ControlSet001'
    if ($selectResult.ExitCode -eq 0) {
        foreach ($line in $selectResult.Output) {
            if ([string]$line -match 'Current\s+REG_DWORD\s+0x([0-9a-fA-F]+)') {
                $currentControlSet = [Convert]::ToInt32($Matches[1], 16)
                if ($currentControlSet -gt 0) {
                    $controlSet = 'ControlSet{0:D3}' -f $currentControlSet
                }
                break
            }
        }
    }
    foreach ($serviceName in @('DiagTrack','dmwappushservice','WSearch','WerSvc')) {
        Set-RegistryValue -Path ('HKLM\zSYSTEM\{0}\Services\{1}' -f $controlSet, $serviceName) -Name 'Start' -Type REG_DWORD -Value '4'
    }
    Set-RegistryValue -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' -Name 'ShippedWithReserves' -Type REG_DWORD -Value '0'
    Set-RegistryValue -Path ('HKLM\zSYSTEM\{0}\Control\BitLocker' -f $controlSet) -Name 'PreventDeviceEncryption' -Type REG_DWORD -Value '1'

    if ($removeEdge) {
        Remove-RegistryKey -Path 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
        Remove-RegistryKey -Path 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update'
    }
    if ($removeOneDrive) {
        Set-RegistryValue -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Type REG_DWORD -Value '1'
    }
    Unload-AllHives
    if ($script:loadedHives.Count -gt 0) {
        throw ('Some registry hives could not be unloaded: {0}' -f ($script:loadedHives -join ', '))
    }

    # Step 13
    Write-Step 'Removing selected diagnostic scheduled tasks'
    $tasks = Join-Path $scratchDir 'Windows\System32\Tasks\Microsoft\Windows'
    foreach ($taskPath in @(
        (Join-Path $tasks 'Application Experience\Microsoft Compatibility Appraiser'),
        (Join-Path $tasks 'Customer Experience Improvement Program'),
        (Join-Path $tasks 'Application Experience\ProgramDataUpdater'),
        (Join-Path $tasks 'Windows Error Reporting\QueueReporting')
    )) {
        if (Test-Path -LiteralPath $taskPath) {
            Remove-Item -LiteralPath $taskPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Step 14
    Write-Step 'Running component cleanup and saving install image'
    $cleanupResult = Invoke-Native -FilePath 'dism.exe' -Arguments @(('/Image:{0}' -f $scratchDir), '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
    if ($cleanupResult.ExitCode -ne 0) {
        throw ('DISM component cleanup failed with exit code {0}. Output: {1}' -f $cleanupResult.ExitCode, (Get-NativeTail -Result $cleanupResult))
    }
    Dismount-WindowsImage -Path $scratchDir -Save -ErrorAction Stop | Out-Null
    $script:installWimMounted = $false

    # Step 15
    Write-Step 'Selecting and patching boot environment (boot.wim)'
    if (-not (Test-Path -LiteralPath $bootWimPath -PathType Leaf)) {
        throw ('Cannot find boot.wim at: {0}' -f $bootWimPath)
    }
    Grant-AdminAccess -Path $bootWimPath
    try { (Get-Item -LiteralPath $bootWimPath -Force).IsReadOnly = $false } catch { }
    Dismount-ScratchMount
    $bootIndex = Select-ImageIndex -ImagePath $bootWimPath -Prompt 'Select the boot.wim image index to patch (usually 2 = Windows Setup)'
    Mount-WindowsImage -ImagePath $bootWimPath -Index $bootIndex -Path $scratchDir -ErrorAction Stop | Out-Null
    $script:bootWimMounted = $true

    $bootSystemHive = Join-Path $scratchDir 'Windows\System32\config\SYSTEM'
    Load-RegistryHive -HiveName 'zSYSTEM' -HiveFile $bootSystemHive
    $bootLabConfig = 'HKLM\zSYSTEM\Setup\LabConfig'
    foreach ($valueName in @('BypassCPUCheck','BypassRAMCheck','BypassSecureBootCheck','BypassStorageCheck','BypassTPMCheck')) {
        Set-RegistryValue -Path $bootLabConfig -Name $valueName -Type REG_DWORD -Value '1'
    }
    Set-RegistryValue -Path 'HKLM\zSYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Type REG_DWORD -Value '1'
    Unload-RegistryHive -HiveName 'zSYSTEM'
    if ($script:loadedHives.Contains('zSYSTEM')) {
        throw 'The boot SYSTEM registry hive could not be unloaded.'
    }
    Dismount-WindowsImage -Path $scratchDir -Save -ErrorAction Stop | Out-Null
    $script:bootWimMounted = $false

    # Step 16
    Write-Step 'Exporting to compressed ESD format'
    $finalEsd = Join-Path $workspaceDir 'sources\install.esd'
    if (Test-Path -LiteralPath $finalEsd) {
        Remove-Item -LiteralPath $finalEsd -Force
    }
    $finalSourceImages = @(Get-WindowsImage -ImagePath $targetWim -ErrorAction Stop)
    if ($finalSourceImages.Count -ne 1) {
        throw ('Expected exactly one image in target WIM before ESD export, found {0}.' -f $finalSourceImages.Count)
    }
    $finalSourceIndex = [int]$finalSourceImages[0].ImageIndex
    Write-Log ('Exporting target WIM index {0} to ESD. This can take a long time...' -f $finalSourceIndex) -Color Gray
    $esdResult = Invoke-Native -FilePath 'dism.exe' -Arguments @(
        '/Export-Image',
        ('/SourceImageFile:{0}' -f $targetWim),
        ('/SourceIndex:{0}' -f $finalSourceIndex),
        ('/DestinationImageFile:{0}' -f $finalEsd),
        '/Compress:recovery',
        '/CheckIntegrity'
    )
    if ($esdResult.ExitCode -ne 0) {
        throw ('DISM ESD export failed with exit code {0}. Output: {1}' -f $esdResult.ExitCode, (Get-NativeTail -Result $esdResult))
    }
    if (-not (Test-Path -LiteralPath $finalEsd -PathType Leaf)) {
        throw 'DISM reported success, but the final install.esd was not created.'
    }
    Remove-Item -LiteralPath $targetWim -Force
    $finalImages = @(Get-WindowsImage -ImagePath $finalEsd -ErrorAction Stop)
    if ($finalImages.Count -ne 1) {
        throw ('Expected exactly one image in final install.esd, found {0}.' -f $finalImages.Count)
    }
    $finalInstallIndex = [int]$finalImages[0].ImageIndex
    Write-Log ('Final install.esd image index: {0}' -f $finalInstallIndex) -Color Gray

    # Step 17
    Write-Step 'Generating and injecting autounattend.xml'
    Write-FixedAutounattend -Path $autounattendPath -Architecture $architecture -InstallIndex $finalInstallIndex
    Copy-Item -LiteralPath $autounattendPath -Destination (Join-Path $workspaceDir 'autounattend.xml') -Force -ErrorAction Stop
    Write-Log 'Answer file copied to the ISO root.' -Color Gray

    # Step 18
    Write-Step 'Compiling final bootable ISO image'
    $adkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools'
    if (-not (Test-Path -LiteralPath $adkRoot)) {
        throw 'Windows ADK Deployment Tools were not found. Install the Windows ADK Deployment Tools component and run again.'
    }
    $oscdimgCandidates = @(Get-ChildItem -LiteralPath $adkRoot -Filter oscdimg.exe -File -Recurse -ErrorAction SilentlyContinue)
    if ($oscdimgCandidates.Count -eq 0) {
        throw ('oscdimg.exe was not found under {0}. Install the Windows ADK Deployment Tools component.' -f $adkRoot)
    }
    $preferredOSCDIMG = @($oscdimgCandidates | Where-Object { $_.FullName -match '\\amd64\\Oscdimg\\oscdimg\.exe$' } | Select-Object -First 1)
    if ($preferredOSCDIMG.Count -gt 0) {
        $OSCDIMG = $preferredOSCDIMG[0].FullName
    }
    else {
        $OSCDIMG = $oscdimgCandidates[0].FullName
    }

    $bootFile = Join-Path $workspaceDir 'boot\etfsboot.com'
    $efiFile = Join-Path $workspaceDir 'efi\microsoft\boot\efisys.bin'
    if (-not (Test-Path -LiteralPath $bootFile -PathType Leaf)) {
        throw ('BIOS boot file was not found: {0}' -f $bootFile)
    }
    if (-not (Test-Path -LiteralPath $efiFile -PathType Leaf)) {
        throw ('UEFI boot file was not found: {0}' -f $efiFile)
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $isoPath = Join-Path $ScratchRoot ('Tiny10_{0}.iso' -f $timestamp)

    # Microsoft recommends a boot-order file for images larger than 4.5 GB.
    $bootOrderRelative = @(
        'boot\bootfix.bin',
        'boot\bootsect.exe',
        'boot\bcd',
        'boot\boot.sdi',
        'boot\bootmgr',
        'boot\etfsboot.com',
        'boot\memtest.exe',
        'boot\memtest.efi',
        'bootmgr',
        'bootmgr.efi',
        'efi\boot\bootx64.efi',
        'efi\microsoft\boot\efisys.bin',
        'sources\boot.wim'
    )
    $bootOrderExisting = @($bootOrderRelative | Where-Object { Test-Path -LiteralPath (Join-Path $workspaceDir $_) -PathType Leaf })
    $bootOrderFile = Join-Path $ScratchRoot 'Tiny10_bootorder.txt'
    [System.IO.File]::WriteAllLines($bootOrderFile, [string[]]$bootOrderExisting, [System.Text.Encoding]::ASCII)

    # Scratch drive and workspace are drive-root paths, so these boot paths contain no spaces.
    $bootArgs = '2#p0,e,b{0}#pEF,e,b{1}' -f $bootFile, $efiFile
    $oscdimgArgs = @('-m','-o','-u2','-udfver102',('-bootdata:{0}' -f $bootArgs),('-yo{0}' -f $bootOrderFile),$workspaceDir,$isoPath)
    & $OSCDIMG @oscdimgArgs
    $oscdimgExit = $LASTEXITCODE
    if ($oscdimgExit -ne 0) {
        throw ('oscdimg compilation failed with exit code {0}.' -f $oscdimgExit)
    }
    if (-not (Test-Path -LiteralPath $isoPath -PathType Leaf)) {
        throw 'oscdimg completed without creating the final ISO.'
    }

    $script:buildSuccess = $true
    Write-Progress -Activity 'Tiny10 Builder' -Completed
    Write-Host ''
    Write-Host '[SUCCESS] Custom ISO built.' -ForegroundColor Green
    Write-Host ('ISO:               {0}' -f $isoPath) -ForegroundColor Green
    Write-Host ('Edition:           {0}' -f $osEdition) -ForegroundColor Green
    Write-Host ('Architecture:      {0}' -f $architecture) -ForegroundColor Green
    Write-Host ('Install index:     {0}' -f $finalInstallIndex) -ForegroundColor Green
    Write-Host ('Boot index:        {0}' -f $bootIndex) -ForegroundColor Green
    Write-Host ('Packages removed:  {0}' -f $script:removedPackages.Count) -ForegroundColor Green
}
catch {
    $script:buildSuccess = $false
    Write-Progress -Activity 'Tiny10 Builder' -Completed
    Write-Host ''
    Write-Host ('[ERROR] Build failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ('See {0} for the detailed transcript, if it was started.' -f $logPath) -ForegroundColor Yellow
}
finally {
    Unload-AllHives

    # Inspect actual mount state instead of relying only on boolean flags.
    try { Dismount-ScratchMount } catch { Write-Warning $_.Exception.Message }

    if (-not $SkipCleanup) {
        foreach ($cleanupPath in @($workspaceDir, $scratchDir, (Join-Path $ScratchRoot 'Tiny10_bootorder.txt'), $autounattendPath)) {
            if (Test-Path -LiteralPath $cleanupPath) {
                Remove-Item -LiteralPath $cleanupPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Intentionally leave any source ISO mounted; eject it normally when finished.
    if ($script:transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

if (-not $script:buildSuccess) {
    exit 1
}
exit 0
