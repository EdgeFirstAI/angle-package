#Requires -Version 7
<#
.SYNOPSIS
  assemble-windows.ps1 — lay out dist-windows-x64/ from build/windows-x64/.

.DESCRIPTION
  Windows analogue of assemble-xcframework.sh. Produces:

    dist-windows-x64/
      bin/libEGL.dll  bin/libGLESv2.dll
      lib/libEGL.dll.lib  lib/libGLESv2.dll.lib      (import libraries)
      pdb/libEGL.dll.pdb  pdb/libGLESv2.dll.pdb      (shipped as -symbols.zip)
      include/{EGL,GLES2,GLES3,KHR}/                 (ANGLE's public headers,
                                                     incl. eglext_angle.h)
      LICENSE                                        (ANGLE's BSD licence)
      BUILD_INFO.txt

  d3dcompiler_47.dll is NOT shipped: Windows 10/11 provide it in System32 and
  ANGLE resolves it by name. -IncludeD3DCompiler copies the SDK redistributable
  ANGLE's build drops into out/ for consumers that need one anyway.

.PARAMETER Tag
  Release tag recorded in BUILD_INFO.txt. Default: v2.1.<position> from
  config/angle.lock.
#>
[CmdletBinding()]
param(
    [string]$Slice = 'windows-x64',
    [string]$Tag = '',
    [string]$AngleSrc = $env:ANGLE_SRC,
    [switch]$IncludeD3DCompiler
)

$ErrorActionPreference = 'Stop'
$PkgDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $AngleSrc) { $AngleSrc = Join-Path (Split-Path $PkgDir -Parent) 'angle' }

function Log([string]$m) { Write-Host "[assemble-windows] $m" -ForegroundColor Blue }
function Die([string]$m) { Write-Host "[assemble-windows error] $m" -ForegroundColor Red; exit 1 }

$Stage = Join-Path $PkgDir "build\$Slice"
$Dist  = Join-Path $PkgDir "dist-$Slice"
$GnOut = Join-Path $AngleSrc "out\angle-pkg-$Slice"
foreach ($f in 'libEGL.dll', 'libGLESv2.dll', 'libEGL.dll.lib', 'libGLESv2.dll.lib', 'libEGL.dll.pdb', 'libGLESv2.dll.pdb') {
    if (-not (Test-Path (Join-Path $Stage $f))) { Die "missing $Stage\$f — run build-windows.ps1 first" }
}

$lock = ConvertFrom-StringData -StringData ((Get-Content (Join-Path $PkgDir 'config\angle.lock') | Where-Object { $_ -match '^[A-Z_]+=' }) -join "`n")
if (-not $Tag) { $Tag = "v2.1.$($lock.ANGLE_COMMIT_POSITION)" }

# ── Layout ───────────────────────────────────────────────────────────────
Remove-Item -Recurse -Force $Dist -ErrorAction Ignore
foreach ($d in 'bin', 'lib', 'pdb', 'include') { New-Item -ItemType Directory -Force (Join-Path $Dist $d) | Out-Null }
Copy-Item (Join-Path $Stage 'libEGL.dll'),      (Join-Path $Stage 'libGLESv2.dll')     (Join-Path $Dist 'bin')
Copy-Item (Join-Path $Stage 'libEGL.dll.lib'),  (Join-Path $Stage 'libGLESv2.dll.lib') (Join-Path $Dist 'lib')
Copy-Item (Join-Path $Stage 'libEGL.dll.pdb'),  (Join-Path $Stage 'libGLESv2.dll.pdb') (Join-Path $Dist 'pdb')
foreach ($d in 'EGL', 'GLES2', 'GLES3', 'KHR') {
    $src = Join-Path $AngleSrc "include\$d"
    if (-not (Test-Path $src)) { Die "ANGLE headers not found at $src" }
    $dst = Join-Path $Dist "include\$d"
    New-Item -ItemType Directory -Force $dst | Out-Null
    # Headers only (the source tree also carries .clang-format files).
    Copy-Item (Join-Path $src '*.h') $dst
}
Copy-Item (Join-Path $AngleSrc 'LICENSE') (Join-Path $Dist 'LICENSE')
if ($IncludeD3DCompiler) {
    $dc = Join-Path $GnOut 'd3dcompiler_47.dll'
    if (-not (Test-Path $dc)) { Die "-IncludeD3DCompiler: $dc not present in the GN output" }
    Copy-Item $dc (Join-Path $Dist 'bin')
    Log "  included d3dcompiler_47.dll (opt-in)"
}

# ── Toolchain strings for BUILD_INFO.txt (best effort) ───────────────────
$clang = 'clang-cl (third_party/llvm-build; version unknown)'
$clangExe = Join-Path $AngleSrc 'third_party\llvm-build\Release+Asserts\bin\clang-cl.exe'
if (Test-Path $clangExe) { try { $clang = (& $clangExe --version 2>$null | Select-Object -First 1).Trim() } catch {} }
$vs = 'unknown'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    try {
        $sel = @('-latest', '-products', '*', '-property', 'catalog_productDisplayVersion')
        if ($env:GYP_MSVS_VERSION) { $sel = @('-version', "[$(if ($env:GYP_MSVS_VERSION -eq '2022') { '17.0,18.0' } elseif ($env:GYP_MSVS_VERSION -eq '2026') { '18.0,19.0' } else { '16.0,' })", '-products', '*', '-property', 'catalog_productDisplayVersion') }
        $vs = (& $vswhere @sel 2>$null | Select-Object -First 1)
        if (-not $vs) { $vs = 'unknown' }
    } catch {}
}
$sdk = $env:WindowsSDKVersion
if (-not $sdk) {
    try { $sdk = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0' -ErrorAction Stop).ProductVersion } catch { $sdk = 'unknown' }
}
$sdk = "$sdk".TrimEnd('\')
$host_ = "$env:COMPUTERNAME ($env:PROCESSOR_ARCHITECTURE)"
if ($env:GITHUB_RUN_ID) { $host_ += " — GitHub Actions run $env:GITHUB_RUN_ID ($env:ImageOS $env:ImageVersion)" }
$gnPos = $lock.ANGLE_COMMIT_POSITION

$info = @"
ANGLE Windows x64 build
=======================
Built:              $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
ANGLE source:       $AngleSrc
ANGLE commit:       $($lock.ANGLE_COMMIT.Substring(0,10)) (position $gnPos)
ANGLE commit date:  $($lock.ANGLE_COMMIT_DATE)
ANGLE branch:       $($lock.ANGLE_BRANCH) (pinned via config/angle.lock)
GL_VERSION string:  OpenGL ES 3.0 (ANGLE 2.1.$gnPos ...)
Build host:         $host_
Toolchain:          $clang; Visual Studio $vs; Windows SDK $sdk; DEPOT_TOOLS_WIN_TOOLCHAIN=0
Slices:             $Slice (Direct3D 11)
Backends:           D3D11 only (GL, Vulkan, SwiftShader, WebGPU, Null disabled)
CRT:                static (is_component_build=false) — no VC++ redistributable required
Signing:            unsigned
Package tag:        $Tag
"@
[IO.File]::WriteAllText((Join-Path $Dist 'BUILD_INFO.txt'), (($info -replace "`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))

Log "Wrote $Dist\BUILD_INFO.txt"
Get-Content (Join-Path $Dist 'BUILD_INFO.txt') | ForEach-Object { Write-Host "    $_" }
Log "Done. Layout at $Dist"
