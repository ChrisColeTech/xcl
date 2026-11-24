# Builds XCL, runs its test suite, inspects the package, and performs a bounded offline smoke run.
[CmdletBinding()]
param(
    [string]$Game,
    [ValidateRange(1, 86400)][int]$Seconds = 120,
    [ValidateRange(1, 256)][int]$BuildJobs = [Math]::Max(1, [int]([Environment]::ProcessorCount / 2)),
    [ValidateRange(1, 64)][int]$TestThreads = 1,
    [ValidateRange(1, 64)][int]$ShaderJobs = 4,
    [string]$Adapter = "5090",
    [ValidateRange(0, 1000000)][int]$FrameDump = 30,
    [switch]$SkipTests,
    [switch]$SkipRun,
    [switch]$PrecompileCompute,
    [switch]$PrecompilePipelines
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$games = Split-Path $root -Parent
if (-not $Game) { $Game = Join-Path $games "GTA6" }
$Game = [IO.Path]::GetFullPath($Game)
if (-not (Test-Path -LiteralPath $Game -PathType Container)) { throw "Game folder not found: $Game" }
$manifest = Join-Path $Game "MicrosoftGame.Config"
$image = Join-Path $Game "game_scarlett_master.exe"
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf) -or
    -not (Test-Path -LiteralPath $image -PathType Leaf)) {
    throw "Game must contain MicrosoftGame.Config and game_scarlett_master.exe: $Game"
}

& (Join-Path $PSScriptRoot "setup.ps1")
if ($LASTEXITCODE -ne 0) { throw "Environment setup failed with exit code $LASTEXITCODE" }

$env:CARGO_BUILD_JOBS = "$BuildJobs"
Set-Location $root
Write-Host "Building XCL release workspace with $BuildJobs jobs"
& cargo build --release --workspace
if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
$xcl = Join-Path $root "target\release\xcl.exe"
if (-not (Test-Path -LiteralPath $xcl -PathType Leaf)) { throw "Build did not produce $xcl" }

if (-not $SkipTests) {
    Write-Host "Building the debug workspace fixtures required by the end-to-end tests"
    & cargo build --workspace
    if ($LASTEXITCODE -ne 0) { throw "cargo debug build failed with exit code $LASTEXITCODE" }
    Write-Host "Running the workspace test suite on $TestThreads test threads"
    & cargo test --workspace -- --test-threads=$TestThreads
    if ($LASTEXITCODE -ne 0) { throw "cargo test failed with exit code $LASTEXITCODE" }
}

Write-Host "Inspecting $image"
& $xcl inspect $image
if ($LASTEXITCODE -ne 0) { throw "xcl inspect failed with exit code $LASTEXITCODE" }

$saved = @{}
foreach ($name in "XCL_NETWORK", "XCL_RUN_SECONDS", "XCL_ACTIVITY", "XCL_ADAPTER", "XCL_DXC_THREADS",
                  "XCL_PIPELINE_THREADS", "XCL_FRAME_DUMP") {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}
try {
    $env:XCL_NETWORK = "0"
    $env:XCL_ACTIVITY = "1"
    $env:XCL_ADAPTER = $Adapter
    $env:XCL_DXC_THREADS = "$ShaderJobs"
    $env:XCL_PIPELINE_THREADS = "$ShaderJobs"
    if ($FrameDump -gt 0) { $env:XCL_FRAME_DUMP = "$FrameDump" } else { Remove-Item Env:XCL_FRAME_DUMP -ErrorAction SilentlyContinue }

    if ($PrecompileCompute -or $PrecompilePipelines) {
        $shaderPack = Join-Path $Game "shaders.rpf"
        $precompile = @("shaders", $shaderPack, "--precompile", "--only", "cs")
        if ($PrecompilePipelines) { $precompile += "--pipelines" }
        Write-Host "Precompiling the compute shader corpus on $Adapter with $ShaderJobs workers"
        & $xcl @precompile
        if ($LASTEXITCODE -ne 0) { throw "xcl shaders failed with exit code $LASTEXITCODE" }
    }

    if (-not $SkipRun) {
        Write-Host "Running an offline $Seconds-second smoke test on adapter '$Adapter'"
        & (Join-Path $PSScriptRoot "smoke.ps1") -Game $Game -Seconds $Seconds -Xcl $xcl
        if ($LASTEXITCODE -ne 0) { throw "smoke.ps1 failed with exit code $LASTEXITCODE" }
    }
} finally {
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
        }
    }
}

Write-Host "SUCCESS: $xcl"
