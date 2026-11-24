# One-time Windows environment setup for XCL. Safe to rerun.
[CmdletBinding()]
param(
    [string]$AgilityVersion = "1.620.2",
    [string]$AgilityDir = (Join-Path $env:LOCALAPPDATA "XCL\D3D12"),
    [switch]$SkipAgility
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

function Require-Command([string]$Name, [string]$Hint) {
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw "$Name was not found. $Hint" }
    return $command.Source
}

if ($env:OS -ne "Windows_NT" -or -not [Environment]::Is64BitOperatingSystem) {
    throw "XCL requires 64-bit Windows 10 or 11."
}

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
$ubr = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
if ($build -lt 19045 -or ($build -eq 19045 -and $ubr -lt 3393)) {
    throw "Windows 10 must be 22H2 build 19045.3393 or newer for an app-supplied Agility SDK."
}

$cargo = Require-Command "cargo" "Install Rust from https://rustup.rs with the MSVC toolchain."
$rustc = Require-Command "rustc" "Install stable-x86_64-pc-windows-msvc."
$rustup = Require-Command "rustup" "Install Rust through rustup."
$toolchain = (& $rustup show active-toolchain 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $toolchain -notmatch "stable-x86_64-pc-windows-msvc") {
    throw "The active Rust toolchain must be stable-x86_64-pc-windows-msvc (found: $toolchain)."
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Visual Studio Installer's vswhere.exe was not found. Install Visual Studio 2022 Build Tools."
}
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "Visual Studio 2022 with Desktop development with C++ was not found." }

$dxcDir = $env:XCL_DXC_DIR
if ($dxcDir -and (-not (Test-Path -LiteralPath (Join-Path $dxcDir "dxcompiler.dll")) -or
                     -not (Test-Path -LiteralPath (Join-Path $dxcDir "dxil.dll")))) {
    throw "XCL_DXC_DIR=$dxcDir does not contain dxcompiler.dll and dxil.dll."
}
if (-not $dxcDir) {
    $kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    $candidates = Get-ChildItem -LiteralPath $kits -Directory -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]$_.Name } catch { [version]"0.0" } } -Descending
    foreach ($candidate in $candidates) {
        $bin = Join-Path $candidate.FullName "x64"
        if ((Test-Path -LiteralPath (Join-Path $bin "dxcompiler.dll")) -and
            (Test-Path -LiteralPath (Join-Path $bin "dxil.dll"))) {
            $dxcDir = $bin
            break
        }
    }
}
if (-not $dxcDir) { throw "DXC was not found. Install a Windows SDK or set XCL_DXC_DIR." }
$dxcVersion = (Get-Item -LiteralPath (Join-Path $dxcDir "dxcompiler.dll")).VersionInfo.FileVersion
$dxcMajorMinor = [version](($dxcVersion -split "\.")[0..1] -join ".")
if ($dxcMajorMinor -lt [version]"1.8") { throw "DXC 1.8 or newer is required; found $dxcVersion in $dxcDir." }
$env:XCL_DXC_DIR = $dxcDir

if (-not $SkipAgility) {
    $core = Join-Path $AgilityDir "D3D12Core.dll"
    $layers = Join-Path $AgilityDir "d3d12SDKLayers.dll"
    if (-not (Test-Path -LiteralPath $core -PathType Leaf) -or
        (Get-AuthenticodeSignature $core).Status -ne "Valid") {
        $packageName = "microsoft.direct3d.d3d12.$AgilityVersion.nupkg"
        $package = Join-Path $env:TEMP $packageName
        $extract = Join-Path $env:TEMP "xcl-agility-$AgilityVersion"
        $url = "https://api.nuget.org/v3-flatcontainer/microsoft.direct3d.d3d12/$AgilityVersion/$packageName"
        $expectedHash = if ($AgilityVersion -eq "1.620.2") {
            "70489669C2BBEAF318B62D72B0AC3E753D521387BFC848C9763791C4E920BFCC"
        } else { throw "No pinned SHA-256 is recorded for Agility SDK $AgilityVersion." }

        Write-Host "Installing Microsoft D3D12 Agility SDK $AgilityVersion to $AgilityDir"
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $package
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $package).Hash -ine $expectedHash) {
            throw "The downloaded Agility SDK package has the wrong SHA-256."
        }
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($package, $extract)
        $source = Join-Path $extract "build\native\bin\x64"
        foreach ($dll in "D3D12Core.dll", "d3d12SDKLayers.dll") {
            $signature = Get-AuthenticodeSignature (Join-Path $source $dll)
            if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "Microsoft Corporation") {
                throw "$dll is not validly signed by Microsoft."
            }
        }
        New-Item -ItemType Directory -Path $AgilityDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $source "D3D12Core.dll"),
            (Join-Path $source "d3d12SDKLayers.dll") -Destination $AgilityDir -Force
        Copy-Item -LiteralPath (Join-Path $extract "LICENSE.txt"),
            (Join-Path $extract "LICENSE-CODE.txt") -Destination $AgilityDir -Force
        Remove-Item -LiteralPath $extract -Recurse -Force
        Remove-Item -LiteralPath $package -Force
    }
    $env:XCL_D3D12_DIR = [IO.Path]::GetFullPath($AgilityDir)
}

$gamingServices = Test-Path -LiteralPath "C:\Windows\System32\xgameruntime.dll" -PathType Leaf
$gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch "Basic" } | Select-Object -ExpandProperty Name)
Write-Host "XCL root       : $root"
Write-Host "Windows        : $($os.Caption) $build.$ubr"
Write-Host "Rust           : $(& $rustc --version)"
Write-Host "Visual Studio  : $vs"
Write-Host "DXC             : $dxcVersion ($dxcDir)"
Write-Host "Agility SDK     : $(if ($SkipAgility) { 'skipped' } else { $env:XCL_D3D12_DIR })"
Write-Host "GPU             : $($gpus -join '; ')"
if (-not $gamingServices) {
    Write-Warning "C:\Windows\System32\xgameruntime.dll is missing. XCL can run, but Gaming Services dialogs and text entry are unavailable."
}
Write-Host "SETUP SUCCESS"
