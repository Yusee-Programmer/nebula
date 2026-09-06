# Build a Nebula program into a browser-loadable .wasm.
#
#   .\scripts\build-web.ps1
#   .\scripts\build-web.ps1 -Source examples\web_demo\render_web.tr -OutDir build-web
#
# Then serve build-web/ over HTTP (a file:// page cannot fetch the .wasm):
#   python3 -m http.server 8000 --directory build-web
#
# Two flags here are load-bearing and were found by running the build without
# them, not by reading docs:
#
#   --freestanding   `--target wasm` ALONE FAILS. tauraro_rt.h includes
#                    <stdio.h>, and bare wasm has no libc. --freestanding
#                    defines TAURARO_KERNEL, which is the same switch the UEFI
#                    and Cortex-M tiers rely on. The cost is that the program
#                    must supply @allocator/@free/@realloc/@calloc itself.
#   -rdynamic        Without it, wasm-ld drops every unreferenced symbol and
#                    the module exports only `memory` and `_start`. Every
#                    `pub export def` silently vanishes, and the host page
#                    fails with "is not a function" at the first call.
#
# The result imports NOTHING -- no WASI, no JS glue contract -- so the host
# page needs only WebAssembly.instantiate.

param(
    [string]$Source = "examples\web_demo\render_web.tr",
    [string]$OutDir = "build-web",
    [int]$MemoryMB  = 64
)

$ErrorActionPreference = "Stop"

$sdk = Join-Path $env:USERPROFILE ".taupkg\bin\tauraroc-windows-x64"
$tauraroc = Join-Path $sdk "tauraroc.exe"
$zig = Join-Path $sdk "zig\zig.exe"
foreach ($t in @($tauraroc, $zig)) { if (-not (Test-Path $t)) { throw "missing tool: $t" } }
if (-not (Test-Path $Source)) { throw "no such source file: $Source" }

$root = (Get-Location).Path
$out = Join-Path $root $OutDir
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null

$srcFull = (Resolve-Path $Source).Path

# Emit C from the repo root, so toolkit.* module paths resolve.
#
# build/ is wiped first: tauraroc emits there, every other tier emits there
# too, and the glob below would otherwise sweep up a previous build's
# leftovers -- which surfaces as "unknown type name 'File'" from a
# module_io_file.c that this program never imported.
$stale = Join-Path $root "build"
if (Test-Path $stale) { Remove-Item $stale -Recurse -Force }

& $tauraroc $srcFull --target wasm --freestanding --emit c
if ($LASTEXITCODE -ne 0) { throw "tauraroc failed (exit $LASTEXITCODE)" }

$csrc = Get-ChildItem -Path (Join-Path $root "build") -Recurse -Filter *.c | ForEach-Object { $_.FullName }
if ($csrc.Count -eq 0) { throw "tauraroc emitted no C sources" }
Write-Host "linking $($csrc.Count) C file(s) for wasm32-freestanding"

$wasm = Join-Path $out "nebula.wasm"
$bytes = $MemoryMB * 1024 * 1024

# -cflags ... -- brackets the flags that apply to the C sources only. -w is
# not laziness: tauraro_rt.h has `while((*d++=*s++));` idioms that zig
# promotes to errors by default.
$zigArgs = @(
    "build-exe",
    "-target", "wasm32-freestanding",
    "-fno-entry",
    "-rdynamic",
    "-O", "ReleaseSmall",
    "--export=__heap_base",
    "--initial-memory=$bytes",
    "--name", "nebula",
    "-femit-bin=`"$wasm`"",
    "-cflags", "-w", "-fno-sanitize=undefined", "--"
) + $csrc

& $zig @zigArgs
if ($LASTEXITCODE -ne 0) { throw "zig build-exe failed (exit $LASTEXITCODE)" }

Copy-Item (Join-Path (Split-Path $srcFull) "index.html") $out -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "built $wasm" -ForegroundColor Green
Write-Host "  $((Get-Item $wasm).Length) bytes, $MemoryMB MB linear memory"
Write-Host ""
Write-Host "serve it with:"
Write-Host "  python3 -m http.server 8000 --directory $OutDir"
Write-Host "  then open http://localhost:8000/"
