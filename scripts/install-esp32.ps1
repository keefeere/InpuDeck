#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Name = "",
    [string]$Passkey = "",
    [string]$Port = "auto",
    [string]$Version = "latest",
    [switch]$SkipFlash,
    [switch]$RotatePasskey,
    [ValidateRange(1, 600)]
    [int]$Timeout = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Repository = "keefeere/InpuDeck"
$SigstoreVersion = "4.1.0"
$SigstoreOidcIssuer = "https://token.actions.githubusercontent.com"
$UvVersion = "0.12.19"
$DefaultBridgeName = "InpuDeck Bridge"
$MinimumAttestedRelease = [version]"3.3.10"

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $Actual = Get-Sha256 -Path $Path
    if ($Actual -ne $Expected.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $([IO.Path]::GetFileName($Path)). Expected $Expected; got $Actual."
    }
}

function Get-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$DiscardOutput
    )
    if ($DiscardOutput) {
        & $Executable @Arguments | Out-Null
    } else {
        & $Executable @Arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$([IO.Path]::GetFileName($Executable)) exited with code $LASTEXITCODE."
    }
}

function Resolve-Release {
    param([Parameter(Mandatory = $true)][string]$RequestedVersion)

    if ($RequestedVersion -eq "latest") {
        if ($env:INPUDECK_RELEASE_BASE) {
            throw "INPUDECK_RELEASE_BASE requires an explicit -Version."
        }
        $Headers = @{ "User-Agent" = "InpuDeck-Windows-Installer" }
        $Latest = Invoke-RestMethod -UseBasicParsing -Headers $Headers `
            -Uri "https://api.github.com/repos/$Repository/releases/latest"
        $Tag = [string]$Latest.tag_name
        if ($Tag -notmatch '^ios-v([0-9]+\.[0-9]+\.[0-9]+)$') {
            throw "Latest release returned an unexpected tag: $Tag"
        }
        $NumericVersion = $Matches[1]
    } else {
        $NumericVersion = $RequestedVersion -replace '^ios-v', ''
        if ($NumericVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
            throw "Version must use the numeric X.Y.Z form or 'latest'."
        }
        $Tag = "ios-v$NumericVersion"
    }

    if ([version]$NumericVersion -lt $MinimumAttestedRelease) {
        throw "The secure Windows installer requires InpuDeck $MinimumAttestedRelease or newer."
    }

    $Base = $env:INPUDECK_RELEASE_BASE
    if (-not $Base) {
        $Base = "https://github.com/$Repository/releases/download/$Tag"
    }
    return @{
        Version = $NumericVersion
        Tag = $Tag
        Base = $Base.TrimEnd('/')
    }
}

function Get-UvExecutable {
    param([Parameter(Mandatory = $true)][string]$WorkDirectory)

    $Installed = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($Installed) {
        return $Installed.Source
    }

    $Architecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $Architecture) {
        $Architecture = $env:PROCESSOR_ARCHITECTURE
    }

    $UvAssets = @{
        "AMD64" = @{
            Name = "uv-x86_64-pc-windows-msvc.zip"
            Sha256 = "6dbb02d79e419522f1c500f0adb1cddcff0cda7d59b0d66ea7f5e3b4a1b2f5f0"
        }
        "ARM64" = @{
            Name = "uv-aarch64-pc-windows-msvc.zip"
            Sha256 = "115b54cb823bc48260670f5782001add6067ac8d98d18c8263a833704e287de9"
        }
        "x86" = @{
            Name = "uv-i686-pc-windows-msvc.zip"
            Sha256 = "e1c2d19d1173a0e9f81ba3f95881ad741808133e372610889ff6870629218c7f"
        }
    }
    if (-not $UvAssets.ContainsKey($Architecture)) {
        throw "Unsupported Windows architecture: $Architecture"
    }

    $Asset = $UvAssets[$Architecture]
    $Archive = Join-Path $WorkDirectory $Asset.Name
    $UvDirectory = Join-Path $WorkDirectory "uv"
    Write-Host "uv was not found; downloading temporary uv $UvVersion for $Architecture..."
    Get-RemoteFile `
        -Uri "https://github.com/astral-sh/uv/releases/download/$UvVersion/$($Asset.Name)" `
        -Destination $Archive
    Assert-Sha256 -Path $Archive -Expected $Asset.Sha256
    Expand-Archive -LiteralPath $Archive -DestinationPath $UvDirectory
    $Uv = Join-Path $UvDirectory "uv.exe"
    if (-not (Test-Path -LiteralPath $Uv -PathType Leaf)) {
        throw "The verified uv archive did not contain uv.exe."
    }
    return $Uv
}

function Confirm-InstallerArguments {
    if ($RotatePasskey -and -not $SkipFlash) {
        throw "-RotatePasskey is only valid together with -SkipFlash."
    }
    if ($Passkey) {
        if ($Passkey -notmatch '^[1-9][0-9]{5}$') {
            throw "Passkey must contain exactly six ASCII digits and cannot start with zero."
        }
        if ($SkipFlash -and -not $RotatePasskey) {
            throw "-Passkey with -SkipFlash requires -RotatePasskey."
        }
    }
}

if ($env:OS -ne "Windows_NT") {
    throw "install-esp32.ps1 supports Windows only. Use install-esp32.sh on Linux or macOS."
}

# Windows PowerShell 5.1 may otherwise negotiate an obsolete TLS version.
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

Confirm-InstallerArguments
$Release = Resolve-Release -RequestedVersion $Version
$WorkDirectory = Join-Path ([IO.Path]::GetTempPath()) `
    ("inpudeck-installer." + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $WorkDirectory | Out-Null
$OldUvCache = $env:UV_CACHE_DIR

try {
    $Assets = @("install-esp32.py", "install-esp32.py.sigstore.json")
    if (-not $SkipFlash) {
        Write-Host "Downloading InpuDeck firmware $($Release.Version)..."
        $Assets = @(
            "InpuDeck-ESP32-S3-Zero.bin",
            "InpuDeck-ESP32-S3-Zero.bin.sha256",
            "InpuDeck-ESP32-S3-Zero.bin.sigstore.json"
        ) + $Assets
    } else {
        Write-Host "Downloading the InpuDeck installer $($Release.Version); firmware will not be reflashed..."
    }

    foreach ($AssetName in $Assets) {
        Get-RemoteFile `
            -Uri "$($Release.Base)/$AssetName" `
            -Destination (Join-Path $WorkDirectory $AssetName)
    }

    $Firmware = Join-Path $WorkDirectory "InpuDeck-ESP32-S3-Zero.bin"
    if (-not $SkipFlash) {
        $ChecksumPath = Join-Path $WorkDirectory "InpuDeck-ESP32-S3-Zero.bin.sha256"
        $Checksum = (Get-Content -LiteralPath $ChecksumPath -Raw).Trim()
        if ($Checksum -notmatch '^([0-9a-f]{64})\s+InpuDeck-ESP32-S3-Zero\.bin$') {
            throw "Malformed firmware checksum file."
        }
        Assert-Sha256 -Path $Firmware -Expected $Matches[1]
    }

    $Uv = Get-UvExecutable -WorkDirectory $WorkDirectory
    $env:UV_CACHE_DIR = Join-Path $WorkDirectory "uv-cache"
    $CertificateIdentity = `
        "https://github.com/$Repository/.github/workflows/build-ios-ipa.yml@refs/tags/$($Release.Tag)"
    $PythonInstaller = Join-Path $WorkDirectory "install-esp32.py"

    Write-Host "Verifying signed provenance for install-esp32.py..."
    Invoke-Checked -Executable $Uv -DiscardOutput -Arguments @(
        "run", "--no-project", "--with", "sigstore==$SigstoreVersion",
        "sigstore", "verify", "identity",
        "--bundle", (Join-Path $WorkDirectory "install-esp32.py.sigstore.json"),
        "--cert-identity", $CertificateIdentity,
        "--cert-oidc-issuer", $SigstoreOidcIssuer,
        $PythonInstaller
    )

    if (-not $SkipFlash) {
        Write-Host "Verifying signed provenance for InpuDeck-ESP32-S3-Zero.bin..."
        Invoke-Checked -Executable $Uv -DiscardOutput -Arguments @(
            "run", "--no-project", "--with", "sigstore==$SigstoreVersion",
            "sigstore", "verify", "identity",
            "--bundle", (Join-Path $WorkDirectory "InpuDeck-ESP32-S3-Zero.bin.sigstore.json"),
            "--cert-identity", $CertificateIdentity,
            "--cert-oidc-issuer", $SigstoreOidcIssuer,
            $Firmware
        )
    }

    # Parse PEP 723 metadata only after the downloaded Python installer is authenticated.
    Invoke-Checked -Executable $Uv -DiscardOutput -Arguments @(
        "run", "--no-project", "--script", $PythonInstaller, "--help"
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = Read-Host "Adapter name [$DefaultBridgeName]"
        if ([string]::IsNullOrWhiteSpace($Name)) {
            $Name = $DefaultBridgeName
        }
    }

    if (-not $SkipFlash) {
        Write-Host ""
        Write-Host "Put ESP32-S3-Zero into flashing mode:"
        Write-Host " 0. Disconnect any other ESP32 boards from this PC."
        Write-Host " 1. Hold the BOOT button."
        Write-Host " 2. Press and release RESET while holding BOOT."
        Write-Host " 3. Release BOOT."
        [void](Read-Host "Press Enter when ready; the COM port will be detected automatically")
        Write-Host "After flashing, press RESET once when the installer asks you to."
    } else {
        Write-Host ""
        Write-Host "Make sure ESP32-S3-Zero is connected and is not in BOOT mode."
        Write-Host "Open the physical provisioning window: hold BOOT for 3-7 seconds"
        Write-Host "while firmware is running, then release it."
        [void](Read-Host "Press Enter after releasing BOOT")
    }

    $InstallerArguments = @(
        "run", "--no-project", "--script", $PythonInstaller,
        "--name", $Name,
        "--timeout", $Timeout.ToString()
    )
    if ($SkipFlash) {
        $InstallerArguments += "--skip-flash"
        if ($RotatePasskey) {
            $InstallerArguments += "--rotate-passkey"
        }
    } else {
        $InstallerArguments += @("--firmware", $Firmware, "--wait-for-reset")
    }
    if ($Passkey) {
        $InstallerArguments += @("--passkey", $Passkey)
    }
    if ($Port -ne "auto") {
        $InstallerArguments += @("--port", $Port)
    }

    Invoke-Checked -Executable $Uv -Arguments $InstallerArguments

    Write-Host ""
    Write-Host "Done. The ESP now advertises as '$Name'."
    if (-not $SkipFlash -or $RotatePasskey) {
        Write-Host "Pairing is open temporarily. Select this ESP in InpuDeck and enter the passkey shown above."
        Write-Warning "This operation replaced the BLE passkey and identity and erased old bonds. Forget the previous adapter in iPhone Settings > Bluetooth and InpuDeck before pairing again."
    } else {
        Write-Host "The existing BLE identity and bonds were preserved."
        Write-Host "To replace the system pairing identity too, rerun with -SkipFlash -RotatePasskey."
    }
} finally {
    $env:UV_CACHE_DIR = $OldUvCache
    if (Test-Path -LiteralPath $WorkDirectory) {
        Remove-Item -LiteralPath $WorkDirectory -Recurse -Force
    }
}
