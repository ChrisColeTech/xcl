# Build Environment Guide

This guide covers a clean Windows environment through a release build, full workspace tests, package inspection and
a bounded offline run of an unpacked Xbox Series package. XCL runs the title's x64 code natively, supplies console
services and recompiles RDNA2 shaders to HLSL and DXIL at run time.

The repository contains no game files, SDK binaries, keys or decryption code. The game package remains read-only;
XCL redirects writes, saves, caches and logs outside it.

## 1. Toolchain

| Tool | Supported version | Purpose |
|---|---:|---|
| Windows | Windows 10 22H2 build 19045.3393+ or Windows 11 x64 | Host operating system |
| Rust | Current stable `x86_64-pc-windows-msvc` | Runtime and tools |
| Visual Studio | 2022 Desktop development with C++ | MSVC linker and native dependencies |
| Windows SDK | Current supported SDK | Windows libraries and DXC fallback |
| DXC | 1.8 or newer | HLSL to DXIL compilation |
| D3D12 Agility SDK | 1.620.2, pinned | Shader Model 6.6 on Windows 10 |
| GPU | D3D12 feature level 12.0, Shader Model 6.6, mesh shaders | Graphics runtime |

Gaming Services is recommended because it supplies `C:\Windows\System32\xgameruntime.dll`. XCL continues without
it, but system dialogs, text entry, invites and streaming integrations are unavailable.

The target machine used by this guide has Rust 1.99.0, Visual Studio 2022 Build Tools, Windows SDK 10.0.26100,
DXC 1.8.2502.11, an Intel Core Ultra 9 285K, 128 GB RAM and an NVIDIA GeForce RTX 5090.

## 2. One-Time Setup

From the repository root:

```powershell
.\scripts\setup.ps1
```

The setup script verifies Windows, Rust, MSVC, the Windows SDK and DXC. On Windows 10 it installs Microsoft's signed
D3D12 Agility SDK 1.620.2 under `%LOCALAPPDATA%\XCL\D3D12`. The package is downloaded from NuGet, checked against
SHA-256 `70489669C2BBEAF318B62D72B0AC3E753D521387BFC848C9763791C4E920BFCC`, and both DLL signatures must name
Microsoft Corporation.

No administrator shell or system `PATH` edit is required. Re-running setup reuses a valid installation.

## 3. Recommended Build And Run

With this layout:

```text
N:\Games\GTA6\
N:\Games\xcl\
```

run:

```powershell
.\scripts\build_game.ps1
```

The wrapper performs:

```text
environment check
    -> cargo build --release --workspace
    -> cargo test --workspace -- --test-threads=1
    -> xcl inspect N:\Games\GTA6\game_scarlett_master.exe
    -> bounded offline smoke run
```

Explicit settings:

```powershell
.\scripts\build_game.ps1 `
    -Game "N:\Games\GTA6" `
    -Seconds 120 `
    -BuildJobs 12 `
    -TestThreads 1 `
    -ShaderJobs 4 `
    -Adapter 5090 `
    -FrameDump 30
```

The smoke run sets `XCL_NETWORK=0`, `XCL_ACTIVITY=1`, `XCL_ADAPTER=5090`, four DXC/pipeline workers and a graceful
`XCL_RUN_SECONDS` limit. It uses XCL's own `scripts/smoke.ps1`; externally killing a run can leave driver work and
large allocations alive until the driver recovers.

`-SkipTests` omits the workspace suite, `-SkipRun` stops after build and inspection, `-PrecompileCompute` fills the
compute DXIL cache before launch, and `-PrecompilePipelines` additionally asks the NVIDIA driver to build compute
pipelines. Precompilation is resumable but is not required for an ordinary first run.

## 4. Direct Commands

Build and test:

```powershell
cargo build --release --workspace
cargo test --workspace -- --test-threads=1
```

Inspect the retail executable without running it:

```powershell
.\target\release\xcl.exe inspect "N:\Games\GTA6\game_scarlett_master.exe"
```

Bounded manual run:

```powershell
$env:XCL_NETWORK = "0"
$env:XCL_RUN_SECONDS = "120"
$env:XCL_ACTIVITY = "1"
$env:XCL_ADAPTER = "5090"
$env:XCL_DXC_THREADS = "4"
.\target\release\xcl.exe run "N:\Games\GTA6"
```

Optional compute precompile:

```powershell
$env:XCL_ADAPTER = "5090"
$env:XCL_PIPELINE_THREADS = "4"
.\target\release\xcl.exe shaders "N:\Games\GTA6\shaders.rpf" --precompile --only cs --pipelines
```

## 5. Output And Cache Contract

Build output:

```text
target/release/xcl.exe
```

Per-title data defaults to:

```text
%LOCALAPPDATA%\XCL\RockstarGamesInc.28872443D20A7\
|-- xcl.toml
|-- overlay\
|-- saves\
|-- pls\
|-- temp\
|-- cache\
`-- logs\
    |-- xcl.log
    |-- report.json
    |-- xcl.prev.log
    `-- report.prev.json
```

Global translated-shader caches default to `%LOCALAPPDATA%\xcl\dxil`. Override title data with `XCL_DATA_ROOT`,
the DXIL cache with `XCL_DXIL_CACHE`, DXC with `XCL_DXC_DIR`, and Agility with `XCL_D3D12_DIR`.

`report.json` records adapter and DXC selection, imports and stubs, D3D12 calls, shaders, audio, crashes and device
removal. `XCL_FRAME_DUMP=N` writes periodic BMP samples and adds non-dark sample counts to the report. A non-dark
sample proves only that sampled pixels were not black; it does not prove correct rendering or gameplay.

## 6. RTX 5090 Guidance

NVIDIA GPUs use 32-lane waves. XCL automatically translates console wave64 compute, mesh and geometry programs into
paired 32-lane halves. Do not force `XCL_SPLIT_WAVE64` during a normal run; doing so changes cache keys and is intended
for comparisons.

Use DXC 1.8 or newer and begin with four shader/compiler workers. Large DXC jobs can consume roughly 0.7 GB each,
and large driver pipeline compiles can consume roughly 1.5 GB each. Leave `XCL_VRAM_ARENAS`, `XCL_ASYNC_PSO`,
`XCL_LAZY_PSO` and `XCL_TRANSLATED_CACHE` at their defaults unless a measured issue requires a comparison.

The repository's canonical suite normally uses four test threads. On this RTX 5090 machine that mode left four
large UMA/descriptor tests in flight, triggered Windows `RADAR_PRE_LEAK_64`, and exited without a Rust failure
summary. The same suite passed serially, so this wrapper defaults to one test thread while retaining four DXC and
driver-pipeline workers for the title run.

`XCL_DRED=1` and `XCL_D3D12_DEBUG=1` are diagnostics, not normal settings. D3D12 debug mode also requires Windows
Graphics Tools and `d3d12SDKLayers.dll`.

## 7. Hypervisor Stability Check

This machine previously produced repeated `HYPERVISOR_ERROR (0x20001)` bugchecks under long concurrent driver
compilation. Disabling only WSL or the Hyper-V optional feature was insufficient because BCD still had
`hypervisorlaunchtype Auto` and VBS was running. After changing boot settings and rebooting, verify:

```powershell
systeminfo | Select-String "hypervisor"
Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard |
    Select-Object VirtualizationBasedSecurityStatus
```

Do not start a long pipeline precompile if Windows still reports that a hypervisor is detected on this machine.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Rust toolchain refusal | GNU, nightly or non-x64 toolchain active | `rustup default stable-x86_64-pc-windows-msvc` |
| `no SM 6.6` on Windows 10 | Agility SDK absent or invalid | Run `scripts\setup.ps1` and keep `XCL_D3D12_DIR` unset or valid |
| DXC missing or too old | No `dxcompiler.dll` and `dxil.dll` pair | Install a current Windows SDK or set `XCL_DXC_DIR` |
| Gaming Services warning | `xgameruntime.dll` absent | Install Gaming Services; core XCL execution can still continue |
| Account picker remains on screen | The bounded smoke run is unattended and the title is waiting for player input | Run in the foreground, confirm `Player1` is shown, then press the displayed confirm button; online account flows still require Gaming Services and Xbox Live |
| GPU test says `SKIPPED` | Adapter or dependency did not run that path | Report skips; use `XCL_REQUIRE_GPU` only when intentionally requiring coverage |
| Cold run shows black/incomplete frames | Graphics PSOs still compiling in the background | Let the bounded run finish, then rerun with the warm cache |
| Device removal | Driver, shader, synchronization or memory fault | Preserve `report.json`; rerun once with DRED rather than changing several flags |
| Commit or memory pressure grows quickly | Too many concurrent DXC/driver compiles | Lower `-ShaderJobs`; keep the Windows page file enabled |

## 9. Verification Record

Record the xcl commit, Windows build, Rust/DXC/Agility versions, GPU and driver, test counts including `SKIPPED`,
inspection result, smoke summary, report path, frames/presents, peak commit, device removals and crashes. Never include
game binaries, extracted data, shader dumps or process dumps in the repository.
