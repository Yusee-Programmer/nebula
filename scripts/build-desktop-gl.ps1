# Build a Tauraro UI program using the GPU-accelerated GlCanvas backend
# (toolkit/render/desktop/gl_canvas.tr, proposal-v6 phase 2). Same shape as
# build-desktop.ps1 -- only the default entry point and output dir differ;
# GlCanvas links against the same SDL2 import lib as SdlCanvas (SDL2 is how
# the GL context/window gets created at all), plus every actual OpenGL
# function is resolved at runtime via SDL_GL_GetProcAddress, so no separate
# opengl32.lib link is needed.
#
#   .\scripts\build-desktop-gl.ps1
#   .\build-desktop-gl\app.exe

param(
    [string]$Source = "examples\gl_smoke\main.tr",
    [string]$OutDir = "build-desktop-gl",
    [string]$MingwRoot = "C:\msys64\mingw64"
)

$ErrorActionPreference = "Stop"

$sdk = Join-Path $env:USERPROFILE ".taupkg\bin\tauraroc-windows-x64"
$tauraroc = Join-Path $sdk "tauraroc.exe"
if (-not (Test-Path $tauraroc)) { throw "missing tool: $tauraroc" }
if (-not (Test-Path $Source)) { throw "no such source file: $Source" }

$sdl2ImportLib = Join-Path $MingwRoot "lib\libSDL2.dll.a"
$sdl2Dll = Join-Path $MingwRoot "bin\SDL2.dll"
foreach ($f in @($sdl2ImportLib, $sdl2Dll)) {
    if (-not (Test-Path $f)) {
        throw "missing SDL2 dev files: $f -- install with: pacman -S mingw-w64-x86_64-SDL2"
    }
}

$root = (Get-Location).Path
$out = Join-Path $root $OutDir
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force $out | Out-Null

$srcFull = (Resolve-Path $Source).Path
$exe = Join-Path $out "app.exe"

Push-Location $out
try {
    & $tauraroc $srcFull --link $sdl2ImportLib -o $exe
    if ($LASTEXITCODE -ne 0) { throw "tauraroc failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

Copy-Item $sdl2Dll (Join-Path $out "SDL2.dll") -Force

Write-Host ""
Write-Host "built $exe" -ForegroundColor Green
Write-Host "  $((Get-Item $exe).Length) bytes, SDL2.dll copied alongside"
Write-Host ""
Write-Host "run it with:"
Write-Host "  .\$OutDir\app.exe"
