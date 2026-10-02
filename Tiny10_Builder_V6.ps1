#Requires -Version 5.1
<#
.SYNOPSIS
    Builds an optimized, lightweight Windows 10 ISO by removing bloatware
    and telemetry.

.DESCRIPTION
    Fixed version:
      - Does not download the old/broken autounattend.xml.
      - Generates a clean answer file.
      - Dynamically selects the install.wim/install.esd index.
      - Dynamically selects the boot.wim index.
      - Does not hardcode boot.wim index 2.
      - Does not hardcode the exported install image index.
      - Validates image indexes before mounting/exporting.
      - Supports customized single-index WIM/ESD sources.
      - Removes an expanded list of unwanted provisioned Appx packages.
      - Uses registry helper functions that work correctly with PowerShell 5.1.
      - Preserves command-line parameters when elevation is required.
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
}
else {
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
$architecture   = $null
$bootIndex      = $null
$finalInstallIndex = $null

# ── Security Principal ─────────────────────────────────────────────────────────
$adminSID = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])

# ── Helper Functions ───────────────────────────────────────────────────────────
$script:stepTotal   = 18
$script:stepCurrent = 0
$script:installWimMounted = $false
$script:bootWimMounted    = $false
$script:removedPackages   = [System.Collections.Generic.List[string]]::new()
$script:buildSuccess      = $false
$script:transcriptStarted = $false

function Write-Log {
    param(
        [string]$Message,
        [ConsoleColor]$Color = 'White'
    )

    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $Message" -ForegroundColor $Color
}

function Write-Step {
    param(
        [string]$Message
    )

    $script:stepCurrent++

    $pct = [int](($script:stepCurrent / $script:stepTotal) * 100)

    Write-Progress `
        -Activity 'Tiny10 Builder' `
        -Status "Step $($script:stepCurrent)/$($script:stepTotal): $Message" `
        -PercentComplete $pct

    Write-Log `
        "── Step $($script:stepCurrent)/$($script:stepTotal): $Message ──" `
        -Color Cyan
}

function Set-RegistryValue {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($PSCmdlet.ShouldProcess("$Path\$Name", 'Set registry value')) {
        try {
            & reg.exe add $Path /v $Name /t $Type /d $Value /f | Out-Null

            if ($LASTEXITCODE -ne 0) {
                Write-Warning `
                    "Registry set returned exit code $LASTEXITCODE: $Path\$Name"
            }
        }
        catch {
            Write-Warning `
                "Registry set failed: $Path\$Name — $_"
        }
    }
}

function Remove-RegistryValue {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($PSCmdlet.ShouldProcess($Path, 'Delete registry key')) {
        try {
            & reg.exe delete $Path /f | Out-Null

            if ($LASTEXITCODE -ne 0) {
                Write-Warning `
                    "Registry delete returned exit code $LASTEXITCODE: $Path"
            }
        }
        catch {
            Write-Warning `
                "Registry delete failed: $Path — $_"
        }
    }
}

function Read-YesNo {
    param(
        [string]$Prompt
    )

    do {
        $a = (Read-Host $Prompt).Trim().ToLower()

        if ($a -notin 'yes','y','no','n') {
            Write-Host `
                'Please enter yes/no (or y/n).' `
                -ForegroundColor Red
        }

    } while ($a -notin 'yes','y','no','n')

    return ($a -in 'yes','y')
}

function Assert-FreeSpace {
    param(
        [string]$Drive,
        [int]$RequiredGB
    )

    $letter = $Drive.TrimEnd(':')[0]

    $vol = Get-PSDrive `
        -Name $letter `
        -ErrorAction SilentlyContinue

    if ($vol) {
        $freeGB = [math]::Round($vol.Free / 1GB, 1)

        if ($vol.Free -lt ($RequiredGB * 1GB)) {
            throw `
                "Insufficient disk space on ${Drive}. Need ${RequiredGB} GB, have ${freeGB} GB."
        }

        Write-Log `
            "Disk space OK: ${freeGB} GB free on ${Drive}." `
            -Color Gray
    }
    else {
        Write-Warning `
            "Could not check disk space on ${Drive} — continuing anyway."
    }
}

function Unload-AllHives {
    foreach ($hive in 'zCOMPONENTS','zDEFAULT','zNTUSER','zSOFTWARE','zSYSTEM') {
        & reg.exe unload "HKLM\$hive" 2>$null | Out-Null
    }
}

function Load-RegistryHive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HiveName,

        [Parameter(Mandatory = $true)]
        [string]$HiveFile
    )

    if (-not (Test-Path $HiveFile)) {
        throw "Registry hive file was not found: $HiveFile"
    }

    & reg.exe load "HKLM\$HiveName" "$HiveFile" | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw `
            "Failed to load registry hive HKLM\$HiveName from $HiveFile. Exit code: $LASTEXITCODE"
    }
}

function Dismount-ScratchMount {
    $mounted = Get-WindowsImage -Mounted -ErrorAction SilentlyContinue

    if ($mounted) {
        foreach ($mount in @($mounted)) {
            if ($mount.Path -eq $scratchDir) {
                Write-Log `
                    "Dismounting existing Tiny10 mount at: $($mount.Path)" `
                    -Color Yellow

                Dismount-WindowsImage `
                    -Path $mount.Path `
                    -Discard `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}

function Select-ImageIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,

        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    $images = @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop)

    if ($images.Count -eq 0) {
        throw "No Windows images were found in: $ImagePath"
    }

    Write-Log `
        "Available images in $ImagePath:" `
        -Color Gray

    $images |
        Format-Table `
            ImageIndex,
            ImageName,
            Architecture,
            ImageDescription `
            -AutoSize

    # If there is exactly one image, automatically use it.
    if ($images.Count -eq 1) {
        $onlyIndex = [int]$images[0].ImageIndex

        Write-Log `
            "Only one image is present. Automatically selecting index $onlyIndex." `
            -Color Green

        return $onlyIndex
    }

    do {
        $inputIndex = Read-Host $Prompt
        $selectedIndex = 0

        if (-not [int]::TryParse($inputIndex, [ref]$selectedIndex)) {
            Write-Host `
                'Invalid index. Please enter a numeric index from the list above.' `
                -ForegroundColor Red

            continue
        }

        $match = $images |
            Where-Object {
                [int]$_.ImageIndex -eq $selectedIndex
            }

        if (-not $match) {
            Write-Host `
                "Index $selectedIndex does not exist in this image." `
                -ForegroundColor Red

            $selectedIndex = 0
        }

    } while ($selectedIndex -eq 0)

    Write-Log `
        "Selected image index: $selectedIndex" `
        -Color Green

    return [int]$selectedIndex
}

function Write-FixedAutounattend {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [int]$InstallIndex
    )

    if ($Architecture -notin 'x86','amd64') {
        throw `
            "Unsupported architecture for answer file: $Architecture"
    }

    if ($InstallIndex -lt 1) {
        throw `
            "Invalid install image index for answer file: $InstallIndex"
    }

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

    <settings pass="oobeSystem">
        <component
            xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            name="Microsoft-Windows-Shell-Setup"
            processorArchitecture="$Architecture"
            publicKeyToken="31bf3856ad364e35"
            language="neutral"
            versionScope="nonSxS">

            <OOBE>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideLocalAccountScreen>false</HideLocalAccountScreen>
                <HideEULAPage>true</HideEULAPage>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>

        </component>
    </settings>

    <settings pass="windowsPE">
        <component
            xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            name="Microsoft-Windows-Setup"
            processorArchitecture="$Architecture"
            publicKeyToken="31bf3856ad364e35"
            language="neutral"
            versionScope="nonSxS">

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
                    <Key/>
                    <WillShowUI>OnError</WillShowUI>
                </ProductKey>

                <AcceptEula>true</AcceptEula>
            </UserData>

        </component>
    </settings>

</unattend>
"@

    Set-Content `
        -Path $Path `
        -Value $xml `
        -Encoding UTF8 `
        -Force

    Write-Log `
        'Generated fixed autounattend.xml.' `
        -Color Gray
}

# ── Execution Policy & Elevation ───────────────────────────────────────────────
if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Host `
        'Changing execution policy to RemoteSigned...' `
        -ForegroundColor Yellow

    Set-ExecutionPolicy `
        RemoteSigned `
        -Scope CurrentUser `
        -Confirm:$false
}

$principal = New-Object `
    System.Security.Principal.WindowsPrincipal(
        [System.Security.Principal.WindowsIdentity]::GetCurrent()
    )

if (-not $principal.IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    Write-Host `
        'Re-launching as Administrator...' `
        -ForegroundColor Cyan

    $p = New-Object System.Diagnostics.ProcessStartInfo

    $p.FileName = 'powershell.exe'

    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$PSCommandPath`""
    )

    if ($PSBoundParameters.ContainsKey('ISO') -and $ISO) {
        $argumentList += '-ISO'
        $argumentList += "`"$ISO`""
    }

    if ($PSBoundParameters.ContainsKey('SCRATCH') -and $SCRATCH) {
        $argumentList += '-SCRATCH'
        $argumentList += "`"$SCRATCH`""
    }

    if ($KeepEdge) {
        $argumentList += '-KeepEdge'
    }

    if ($KeepOneDrive) {
        $argumentList += '-KeepOneDrive'
    }

    if ($SkipCleanup) {
        $argumentList += '-SkipCleanup'
    }

    $p.Arguments = $argumentList -join ' '
    $p.Verb = 'runas'

    [System.Diagnostics.Process]::Start($p) | Out-Null

    exit
}

# ── Transcript ─────────────────────────────────────────────────────────────────
Start-Transcript -Path $logPath -Force
$script:transcriptStarted = $true

$Host.UI.RawUI.WindowTitle = 'Tiny10 Builder'

Clear-Host

Write-Host '════════════════════════════════════════════' -ForegroundColor Green
Write-Host '           Tiny10 Builder Optimized         ' -ForegroundColor Green
Write-Host '════════════════════════════════════════════' -ForegroundColor Green

try {

    # ── Step 1: Answer File Configuration ─────────────────────────────────────
    Write-Step 'Preparing answer file configuration'

    Write-Log `
        'The answer file is generated locally; the previous GitHub XML is not downloaded.' `
        -Color Gray

    # ── Step 2: Build Options ──────────────────────────────────────────────────
    Write-Step 'Gathering build options'

    $removeEdge =
        if ($KeepEdge) {
            $false
        }
        else {
            Read-YesNo 'Remove Microsoft Edge?   (yes/no)'
        }

    $removeOneDrive =
        if ($KeepOneDrive) {
            $false
        }
        else {
            Read-YesNo 'Remove OneDrive?          (yes/no)'
        }

    # ── Step 3: Source Drive Selection ─────────────────────────────────────────
    Write-Step 'Selecting source drive'

    do {

        if (-not $ISO) {
            $DriveLetter = Read-Host `
                'Enter the drive letter of your mounted ISO (e.g. D)'
        }
        else {
            $DriveLetter = $ISO
        }

        $DriveLetter = `
            $DriveLetter.Trim().TrimEnd(':').TrimEnd('\').Trim()

        if ($DriveLetter -match '^[c-zC-Z]$') {
            $DriveLetter += ':'
        }
        else {
            Write-Host `
                'Invalid entry.' `
                -ForegroundColor Red

            $ISO = $null
        }

    } while ($DriveLetter -notmatch '^[c-zC-Z]:$')

    if (-not (Test-Path $DriveLetter)) {
        throw "Drive $DriveLetter could not be accessed."
    }

    $installWim = Join-Path $DriveLetter 'sources\install.wim'
    $installEsd = Join-Path $DriveLetter 'sources\install.esd'

    $targetWim = Join-Path `
        $workspaceDir `
        'sources\install.wim'

    if (
        -not (Test-Path $installWim) -and
        -not (Test-Path $installEsd)
    ) {
        throw `
            "Cannot find install.wim or install.esd on $DriveLetter"
    }

    $srcPath =
        if (Test-Path $installWim) {
            $installWim
        }
        else {
            $installEsd
        }

    Write-Log `
        "Source image: $srcPath" `
        -Color Gray

    # ── Step 4: Disk Space Check ───────────────────────────────────────────────
    Write-Step 'Checking available disk space'

    Assert-FreeSpace `
        -Drive $ScratchDisk `
        -RequiredGB 25

    # ── Step 5: Workspace Initialization ───────────────────────────────────────
    Write-Step 'Initializing build workspace'

    foreach ($dir in $workspaceDir, $scratchDir) {

        if (Test-Path $dir) {
            Remove-Item `
                $dir `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    New-Item `
        -ItemType Directory `
        -Force `
        -Path (Join-Path $workspaceDir 'sources') |
        Out-Null

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $scratchDir |
        Out-Null

    # ── Step 6: Copy ISO Source Structure ──────────────────────────────────────
    Write-Step 'Copying ISO source structure'

    Get-ChildItem `
        -Path $DriveLetter `
        -Recurse `
        -Exclude 'install.wim','install.esd' |
        Where-Object {
            -not $_.PSIsContainer
        } |
        ForEach-Object {

            $relative =
                $_.FullName.
                    Substring($DriveLetter.Length).
                    TrimStart('\')

            $dest = Join-Path `
                $workspaceDir `
                $relative

            $destDir = Split-Path `
                $dest `
                -Parent

            if (-not (Test-Path $destDir)) {
                New-Item `
                    -ItemType Directory `
                    -Force `
                    -Path $destDir |
                    Out-Null
            }

            Copy-Item `
                -Path $_.FullName `
                -Destination $dest `
                -Force `
                -ErrorAction SilentlyContinue
        }

    # Verify critical source files.
    $bootWimPath = Join-Path `
        $workspaceDir `
        'sources\boot.wim'

    if (-not (Test-Path $bootWimPath)) {
        throw `
            "boot.wim was not copied to the workspace."
    }

    # ── Step 7: Image Extraction ───────────────────────────────────────────────
    Write-Step 'Selecting and extracting Windows image'

    $sourceIndex =
        Select-ImageIndex `
            -ImagePath $srcPath `
            -Prompt 'Select the install image index to build'

    Export-WindowsImage `
        -SourceImagePath $srcPath `
        -SourceIndex $sourceIndex `
        -DestinationImagePath $targetWim `
        -CompressionType Maximum `
        -ErrorAction Stop

    if (-not (Test-Path $targetWim)) {
        throw `
            'DISM reported success, but the exported target WIM was not created.'
    }

    # ── Step 8: Mount Install Image ────────────────────────────────────────────
    Write-Step 'Mounting Windows image'

    & takeown.exe `
        "/F" `
        $targetWim |
        Out-Null

    & icacls.exe `
        $targetWim `
        "/grant" `
        "$($adminGroup.Value):(F)" |
        Out-Null

    Set-ItemProperty `
        -Path $targetWim `
        -Name IsReadOnly `
        -Value $false `
        -ErrorAction SilentlyContinue

    Dismount-ScratchMount

    $targetImages =
        @(Get-WindowsImage `
            -ImagePath $targetWim `
            -ErrorAction Stop)

    if ($targetImages.Count -eq 0) {
        throw `
            'No image was found in the exported target WIM.'
    }

    if ($targetImages.Count -ne 1) {
        throw `
            "Expected exactly one image in the exported target WIM, found $($targetImages.Count)."
    }

    $targetIndex =
        [int]$targetImages[0].ImageIndex

    Write-Log `
        "Exported target WIM index: $targetIndex" `
        -Color Gray

    Mount-WindowsImage `
        -ImagePath $targetWim `
        -Index $targetIndex `
        -Path $scratchDir `
        -ErrorAction Stop

    $script:installWimMounted = $true

    $wimInfo =
        Get-WindowsImage `
            -ImagePath $targetWim `
            -Index $targetIndex `
            -ErrorAction Stop

    switch ([int]$wimInfo.Architecture) {

        0 {
            $architecture = 'x86'
        }

        9 {
            $architecture = 'amd64'
        }

        default {
            throw `
                "Unsupported Windows image architecture value: $($wimInfo.Architecture)"
        }
    }

    $osEdition = $wimInfo.ImageName

    Write-Log `
        "Selected edition: $osEdition" `
        -Color Gray

    Write-Log `
        "Architecture: $architecture" `
        -Color Gray

    # ── Step 9: Bloatware Package Removal ─────────────────────────────────────
    Write-Step 'Removing bloatware packages'

    $packages =
        & dism.exe `
            "/image:$scratchDir" `
            '/Get-ProvisionedAppxPackages' |
            ForEach-Object {

                if ($_ -match 'PackageName : (.*)') {
                    $matches[1].Trim()
                }
            }

    # Complete package-family list supplied for Tiny10.
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

    if (-not $packages) {
        Write-Log `
            'No provisioned Appx packages were returned by DISM.' `
            -Color Yellow
    }
    else {

        foreach ($pkg in @($packages)) {

            # Example:
            # Microsoft.BingWeather_4.53.12345.0_neutral__8wekyb3d8bbwe
            #
            # Everything before the first underscore is the package family.
            $packageFamily =
                ($pkg -split '_', 2)[0]

            $shouldRemove = $false

            foreach ($prefix in $packagePrefixes) {

                if (
                    $packageFamily -ieq $prefix -or
                    $packageFamily -like "$prefix*"
                ) {
                    $shouldRemove = $true
                    break
                }
            }

            if ($shouldRemove) {

                Write-Log `
                    "Removing provisioned package: $pkg" `
                    -Color DarkYellow

                & dism.exe `
                    "/image:$scratchDir" `
                    '/Remove-ProvisionedAppxPackage' `
                    "/PackageName:$pkg" |
                    Out-Null

                if ($LASTEXITCODE -eq 0) {

                    $script:removedPackages.Add($pkg)

                }
                else {

                    Write-Warning `
                        "Failed to remove package '$pkg'. DISM exit code: $LASTEXITCODE"
                }
            }
        }
    }

    Write-Log `
        "Provisioned packages removed successfully: $($script:removedPackages.Count)" `
        -Color Green

    # ── Step 10: Windows Capability Removal ────────────────────────────────────
    Write-Step 'Stripping unnecessary Windows capabilities'

    $capPrefixes = @(
        'Browser.InternetExplorer',
        'MathRecognizer',
        'App.StepsRecorder',
        'Hello.Face'
    )

    foreach (
        $cap in @(
            Get-WindowsCapability `
                -Path $scratchDir `
                -ErrorAction SilentlyContinue
        )
    ) {

        if ($cap.State -eq 'Installed') {

            foreach ($prefix in $capPrefixes) {

                if ($cap.Name -like "$prefix*") {

                    Write-Log `
                        "Removing Capability: $($cap.Name)" `
                        -Color DarkYellow

                    Remove-WindowsCapability `
                        -Path $scratchDir `
                        -Name $cap.Name `
                        -ErrorAction SilentlyContinue |
                        Out-Null

                    break
                }
            }
        }
    }

    # ── Step 11: Edge / OneDrive File Removal ──────────────────────────────────
    Write-Step 'Removing optional system components'

    if ($removeEdge) {

        foreach (
            $p in @(
                "$scratchDir\Program Files (x86)\Microsoft\Edge",
                "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate",
                "$scratchDir\Program Files (x86)\Microsoft\EdgeCore"
            )
        ) {

            if (Test-Path $p) {

                Remove-Item `
                    -Path $p `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }

        $webview =
            "$scratchDir\Windows\System32\Microsoft-Edge-Webview"

        if (Test-Path $webview) {

            & takeown.exe `
                '/f' `
                $webview `
                '/r' |
                Out-Null

            & icacls.exe `
                $webview `
                '/grant' `
                "$($adminGroup.Value):(F)" `
                '/T' `
                '/C' |
                Out-Null

            Remove-Item `
                -Path $webview `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    if ($removeOneDrive) {

        $odBin =
            "$scratchDir\Windows\System32\OneDriveSetup.exe"

        if (Test-Path $odBin) {

            & takeown.exe `
                "/f" `
                $odBin |
                Out-Null

            & icacls.exe `
                $odBin `
                "/grant" `
                "$($adminGroup.Value):(F)" |
                Out-Null

            Remove-Item `
                -Path $odBin `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    # ── Step 12: Offline Registry Tweaks ────────────────────────────────────────
    Write-Step 'Applying privacy and system performance tweaks'

    Load-RegistryHive `
        -HiveName 'zCOMPONENTS' `
        -HiveFile "$scratchDir\Windows\System32\config\COMPONENTS"

    Load-RegistryHive `
        -HiveName 'zDEFAULT' `
        -HiveFile "$scratchDir\Windows\System32\config\default"

    Load-RegistryHive `
        -HiveName 'zNTUSER' `
        -HiveFile "$scratchDir\Users\Default\ntuser.dat"

    Load-RegistryHive `
        -HiveName 'zSOFTWARE' `
        -HiveFile "$scratchDir\Windows\System32\config\SOFTWARE"

    Load-RegistryHive `
        -HiveName 'zSYSTEM' `
        -HiveFile "$scratchDir\Windows\System32\config\SYSTEM"

    foreach ($hive in 'zDEFAULT','zNTUSER') {

        Set-RegistryValue `
            "HKLM\$hive\Control Panel\UnsupportedHardwareNotificationCache" `
            'SV1' `
            'REG_DWORD' `
            '0'

        Set-RegistryValue `
            "HKLM\$hive\Control Panel\UnsupportedHardwareNotificationCache" `
            'SV2' `
            'REG_DWORD' `
            '0'
    }

    $cdm =
        'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

    Set-RegistryValue `
        $cdm `
        'OemPreInstalledAppsEnabled' `
        'REG_DWORD' `
        '0'

    Set-RegistryValue `
        $cdm `
        'PreInstalledAppsEnabled' `
        'REG_DWORD' `
        '0'

    Set-RegistryValue `
        $cdm `
        'SilentInstalledAppsEnabled' `
        'REG_DWORD' `
        '0'

    Set-RegistryValue `
        'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' `
        'DisableWindowsConsumerFeatures' `
        'REG_DWORD' `
        '1'

    Set-RegistryValue `
        'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' `
        'Enabled' `
        'REG_DWORD' `
        '0'

    Set-RegistryValue `
        'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search' `
        'DisableWebSearch' `
        'REG_DWORD' `
        '1'

    Set-RegistryValue `
        'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search' `
        'ConnectedSearchUseWeb' `
        'REG_DWORD' `
        '0'

    Set-RegistryValue `
        'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search' `
        'AllowCortana' `
        'REG_DWORD' `
        '0'

    Set-RegistryValue `
        'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' `
        'TailoredExperiencesWithDiagnosticDataEnabled' `
        'REG_DWORD' `
        '0'

    Set-RegistryValue `
        'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' `
        'AllowTelemetry' `
        'REG_DWORD' `
        '0'

    $labConfig =
        'HKLM\zSYSTEM\Setup\LabConfig'

    foreach (
        $key in @(
            'BypassCPUCheck',
            'BypassRAMCheck',
            'BypassSecureBootCheck',
            'BypassStorageCheck',
            'BypassTPMCheck'
        )
    ) {

        Set-RegistryValue `
            $labConfig `
            $key `
            'REG_DWORD' `
            '1'
    }

    Set-RegistryValue `
        'HKLM\zSYSTEM\Setup\MoSetup' `
        'AllowUpgradesWithUnsupportedTPMOrCPU' `
        'REG_DWORD' `
        '1'

    foreach (
        $svc in @(
            'DiagTrack',
            'dmwappushservice',
            'WSearch',
            'WerSvc'
        )
    ) {

        Set-RegistryValue `
            "HKLM\zSYSTEM\ControlSet001\Services\$svc" `
            'Start' `
            'REG_DWORD' `
            '4'
    }

    Set-RegistryValue `
        'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' `
        'ShippedWithReserves' `
        'REG_DWORD' `
        '0'

    Set-RegistryValue `
        'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' `
        'PreventDeviceEncryption' `
        'REG_DWORD' `
        '1'

    if ($removeEdge) {

        Remove-RegistryValue `
            'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'

        Remove-RegistryValue `
            'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update'
    }

    if ($removeOneDrive) {

        Set-RegistryValue `
            'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' `
            'DisableFileSyncNGSC' `
            'REG_DWORD' `
            '1'
    }

    Unload-AllHives

    # ── Step 13: Scheduled Task Removal ────────────────────────────────────────
    Write-Step 'Removing diagnostic scheduled tasks'

    $tasks =
        "$scratchDir\Windows\System32\Tasks\Microsoft\Windows"

    Remove-Item `
        "$tasks\Application Experience\Microsoft Compatibility Appraiser" `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        "$tasks\Customer Experience Improvement Program" `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        "$tasks\Application Experience\ProgramDataUpdater" `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        "$tasks\Windows Error Reporting\QueueReporting" `
        -Force `
        -ErrorAction SilentlyContinue

    # ── Step 14: Component Cleanup & Dismount Install Image ───────────────────
    Write-Step 'Running component cleanup and saving install image'

    & dism.exe `
        /Image:"$scratchDir" `
        /Cleanup-Image `
        /StartComponentCleanup `
        /ResetBase |
        Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw `
            "DISM component cleanup failed with exit code $LASTEXITCODE."
    }

    Dismount-WindowsImage `
        -Path $scratchDir `
        -Save `
        -ErrorAction Stop

    $script:installWimMounted = $false

    # ── Step 15: Boot Environment Patching ─────────────────────────────────────
    Write-Step 'Selecting and patching boot environment (boot.wim)'

    if (-not (Test-Path $bootWimPath)) {
        throw `
            "Cannot find boot.wim at: $bootWimPath"
    }

    & takeown.exe `
        "/F" `
        $bootWimPath |
        Out-Null

    & icacls.exe `
        $bootWimPath `
        "/grant" `
        "$($adminGroup.Value):(F)" |
        Out-Null

    Set-ItemProperty `
        -Path $bootWimPath `
        -Name IsReadOnly `
        -Value $false `
        -ErrorAction SilentlyContinue

    Dismount-ScratchMount

    # IMPORTANT:
    # Never assume boot.wim is index 2.
    #
    # The script examines the actual indexes in boot.wim.
    # If there is only one index, it is selected automatically.
    $bootIndex =
        Select-ImageIndex `
            -ImagePath $bootWimPath `
            -Prompt 'Select the boot.wim image index to patch'

    Mount-WindowsImage `
        -ImagePath $bootWimPath `
        -Index $bootIndex `
        -Path $scratchDir `
        -ErrorAction Stop

    $script:bootWimMounted = $true

    $bootSystemHive =
        "$scratchDir\Windows\System32\config\SYSTEM"

    Load-RegistryHive `
        -HiveName 'zSYSTEM' `
        -HiveFile $bootSystemHive

    $bootLabConfig =
        'HKLM\zSYSTEM\Setup\LabConfig'

    foreach (
        $key in @(
            'BypassCPUCheck',
            'BypassRAMCheck',
            'BypassSecureBootCheck',
            'BypassStorageCheck',
            'BypassTPMCheck'
        )
    ) {

        Set-RegistryValue `
            $bootLabConfig `
            $key `
            'REG_DWORD' `
            '1'
    }

    Set-RegistryValue `
        'HKLM\zSYSTEM\Setup\MoSetup' `
        'AllowUpgradesWithUnsupportedTPMOrCPU' `
        'REG_DWORD' `
        '1'

    & reg.exe unload HKLM\zSYSTEM | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Warning `
            "Failed to unload boot SYSTEM hive. Exit code: $LASTEXITCODE"
    }

    Dismount-WindowsImage `
        -Path $scratchDir `
        -Save `
        -ErrorAction Stop

    $script:bootWimMounted = $false

    # ── Step 16: Export to Compact ESD ─────────────────────────────────────────
    Write-Step 'Exporting to highly compressed solid ESD format'

    $finalEsd =
        Join-Path `
            $workspaceDir `
            'sources\install.esd'

    # Read the target WIM dynamically instead of assuming index 1.
    $finalSourceImages =
        @(Get-WindowsImage `
            -ImagePath $targetWim `
            -ErrorAction Stop)

    if ($finalSourceImages.Count -eq 0) {
        throw `
            'No images found in target WIM before ESD export.'
    }

    if ($finalSourceImages.Count -ne 1) {
        throw `
            "Expected exactly one image in target WIM before ESD export, found $($finalSourceImages.Count)."
    }

    $finalSourceIndex =
        [int]$finalSourceImages[0].ImageIndex

    Write-Log `
        "Exporting target WIM index $finalSourceIndex to ESD." `
        -Color Gray

    & dism.exe `
        /Export-Image `
        /SourceImageFile:$targetWim `
        /SourceIndex:$finalSourceIndex `
        /DestinationImageFile:$finalEsd `
        /Compress:recovery |
        Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw `
            "DISM ESD export failed with exit code $LASTEXITCODE."
    }

    if (-not (Test-Path $finalEsd)) {
        throw `
            'DISM reported success, but the final install.esd was not created.'
    }

    Remove-Item `
        -Path $targetWim `
        -Force `
        -ErrorAction SilentlyContinue

    # Verify final ESD and get its real index.
    $finalImages =
        @(Get-WindowsImage `
            -ImagePath $finalEsd `
            -ErrorAction Stop)

    if ($finalImages.Count -eq 0) {
        throw `
            'No image was found in the final install.esd.'
    }

    if ($finalImages.Count -ne 1) {
        throw `
            "Expected exactly one image in final install.esd, found $($finalImages.Count)."
    }

    $finalInstallIndex =
        [int]$finalImages[0].ImageIndex

    Write-Log `
        "Final install.esd image index: $finalInstallIndex" `
        -Color Gray

    # ── Step 17: Generate and Inject Answer File ───────────────────────────────
    Write-Step 'Generating and injecting fixed autounattend.xml'

    Write-FixedAutounattend `
        -Path $autounattendPath `
        -Architecture $architecture `
        -InstallIndex $finalInstallIndex

    Copy-Item `
        -Path $autounattendPath `
        -Destination (Join-Path $workspaceDir 'autounattend.xml') `
        -Force `
        -ErrorAction Stop

    Write-Log `
        'Fixed OOBE configuration injected into ISO root.' `
        -Color Gray

    # ── Step 18: Compile ISO ───────────────────────────────────────────────────
    Write-Step 'Compiling final bootable ISO image'

    $ADKPath =
        "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$architecture\Oscdimg"

    if (Test-Path $ADKPath) {

        $OSCDIMG =
            Join-Path `
                $ADKPath `
                'oscdimg.exe'
    }
    else {

        if (-not (Test-Path $localOSCDIMGPath)) {

            Write-Log `
                'OSCDIMG was not found in the Windows ADK. Downloading fallback copy...' `
                -Color Yellow

            Invoke-WebRequest `
                -Uri 'https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe' `
                -OutFile $localOSCDIMGPath `
                -ErrorAction Stop
        }

        $OSCDIMG =
            $localOSCDIMGPath
    }

    if (-not (Test-Path $OSCDIMG)) {
        throw `
            'oscdimg.exe could not be found.'
    }

    $bootFile =
        Join-Path `
            $workspaceDir `
            'boot\etfsboot.com'

    $efiFile =
        Join-Path `
            $workspaceDir `
            'efi\microsoft\boot\efisys.bin'

    if (-not (Test-Path $bootFile)) {
        throw `
            "BIOS boot file was not found: $bootFile"
    }

    if (-not (Test-Path $efiFile)) {
        throw `
            "UEFI boot file was not found: $efiFile"
    }

    $timestamp =
        Get-Date -Format 'yyyyMMdd-HHmm'

    $isoPath =
        Join-Path `
            $ScratchDisk `
            "Tiny10_$timestamp.iso"

    $bootArgs =
        "2#p0,e,b`"$bootFile`"#" +
        "pEF,e,b`"$efiFile`""

    & "$OSCDIMG" `
        '-m' `
        '-o' `
        '-u2' `
        '-udfver102' `
        "-bootdata:$bootArgs" `
        "$workspaceDir" `
        "$isoPath"

    if ($LASTEXITCODE -ne 0) {
        throw `
            "oscdimg compilation failed with exit code $LASTEXITCODE."
    }

    if (-not (Test-Path $isoPath)) {
        throw `
            'oscdimg completed without creating the final ISO.'
    }

    $script:buildSuccess = $true

    # ── Build Summary ──────────────────────────────────────────────────────────
    Write-Progress `
        -Activity 'Tiny10 Builder' `
        -Completed

    Write-Host ''
    Write-Host '[SUCCESS] Custom lightweight ISO built.' -ForegroundColor Green
    Write-Host "ISO:               $isoPath" -ForegroundColor Green
    Write-Host "Edition:           $osEdition" -ForegroundColor Green
    Write-Host "Architecture:      $architecture" -ForegroundColor Green
    Write-Host "Install index:     $finalInstallIndex" -ForegroundColor Green
    Write-Host "Boot index:        $bootIndex" -ForegroundColor Green
    Write-Host "Packages removed:  $($script:removedPackages.Count)" -ForegroundColor Green
}
catch {

    Write-Progress `
        -Activity 'Tiny10 Builder' `
        -Completed

    Write-Host ''
    Write-Host "[ERROR] Build failed: $_" -ForegroundColor Red
    Write-Host 'See Output.log for the detailed transcript.' -ForegroundColor Yellow
}
finally {

    # Always attempt to unload our offline registry hives.
    Unload-AllHives

    if (
        $script:installWimMounted -or
        $script:bootWimMounted
    ) {

        Dismount-WindowsImage `
            -Path $scratchDir `
            -Discard `
            -ErrorAction SilentlyContinue
    }

    if (-not $SkipCleanup) {

        Remove-Item `
            -Path $workspaceDir `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        Remove-Item `
            -Path $scratchDir `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue

        Remove-Item `
            -Path $localOSCDIMGPath `
            -Force `
            -ErrorAction SilentlyContinue
    }

    # The source ISO is intentionally left mounted.
    # This avoids trying to infer the disk image from a volume object,
    # which is unreliable. You can eject the ISO normally after the build.

    if ($script:transcriptStarted) {
        Stop-Transcript
    }
}
