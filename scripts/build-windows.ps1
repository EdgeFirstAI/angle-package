#Requires -Version 7
<#
.SYNOPSIS
  build-windows.ps1 — build ONE Windows ANGLE slice (Direct3D 11 backend).

.DESCRIPTION
  Windows analogue of build-slice.sh. Reads config/gn-args-<slice>.gnargs,
  copies it verbatim to <ANGLE_SRC>/out/angle-pkg-<slice>/args.gn (GN accepts
  comments; this sidesteps .bat quote-mangling of `--args=`), runs `gn gen`
  and ANGLE's own ninja.exe for libEGL + libGLESv2, and stages the DLLs,
  import libraries and PDBs into build/<slice>/.

  PowerShell rather than bash because depot_tools' Windows entry points are
  .bat files and MSYS path conversion mangles /-style flags.

.PARAMETER Slice
  Slice name (default windows-x64) -> config/gn-args-<slice>.gnargs.
.PARAMETER AngleSrc
  ANGLE checkout. Default: $env:ANGLE_SRC, else ../angle next to this package.
.PARAMETER DepotTools
  depot_tools checkout. Default: $env:DEPOT_TOOLS, else ../depot_tools.
.PARAMETER SkipPinCheck
  Do not assert the checkout matches config/angle.lock (ANGLE_PIN_CHECK=0 on
  the Mac side). The build then reports whatever position the checkout has.

.NOTES
  Toolchain environment consumed by Chromium's build/vs_toolchain.py:
    DEPOT_TOOLS_WIN_TOOLCHAIN=0   (set here) use the locally installed VS/SDK
    GYP_MSVS_VERSION=2022|2026    optional; pick a VS major when several exist
    vs2022_install / vs2026_install
                                  optional; explicit VS install path
  clang-cl / lld-link come from <ANGLE_SRC>/third_party/llvm-build; MSVC only
  supplies CRT headers/libs and the Windows SDK environment.
#>
[CmdletBinding()]
param(
    [string]$Slice = 'windows-x64',
    [string]$AngleSrc = $env:ANGLE_SRC,
    [string]$DepotTools = $env:DEPOT_TOOLS,
    [switch]$SkipPinCheck
)

$ErrorActionPreference = 'Stop'
$PkgDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Parent = Split-Path $PkgDir -Parent
if (-not $AngleSrc)   { $AngleSrc   = Join-Path $Parent 'angle' }
if (-not $DepotTools) { $DepotTools = Join-Path $Parent 'depot_tools' }

function Log([string]$m) { Write-Host "[build-windows:$Slice] $m" -ForegroundColor Blue }
function Die([string]$m) { Write-Host "[build-windows:$Slice error] $m" -ForegroundColor Red; exit 1 }

# ── Preconditions ────────────────────────────────────────────────────────
$Config = Join-Path $PkgDir "config\gn-args-$Slice.gnargs"
if (-not (Test-Path $Config)) { Die "no GN args config for slice '$Slice' at $Config" }
if (-not (Test-Path (Join-Path $DepotTools 'gn.bat'))) {
    Die "depot_tools not found at $DepotTools (clone https://chromium.googlesource.com/chromium/tools/depot_tools.git there, or set DEPOT_TOOLS)"
}
if (-not (Test-Path (Join-Path $AngleSrc 'DEPS'))) {
    Die "ANGLE source not found at $AngleSrc (clone https://chromium.googlesource.com/angle/angle.git there, or set ANGLE_SRC)"
}
if (-not (Get-ChildItem (Join-Path $AngleSrc 'third_party\abseil-cpp') -ErrorAction Ignore)) {
    Die "ANGLE tree at $AngleSrc is not synced (third_party/abseil-cpp is empty). Run 'gclient sync -D --no-history' there first."
}
$Ninja = Join-Path $AngleSrc 'third_party\ninja\ninja.exe'
if (-not (Test-Path $Ninja)) { Die "ninja not found at $Ninja (gclient sync fetches it)" }

# Chromium's build/ scripts: use the locally installed Visual Studio + SDK.
# depot_tools goes on PATH in-process only — never persist it (its python3.bat
# would shadow the system Python for everything else).
$env:PATH = "$DepotTools;$env:PATH"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'

# depot_tools on Windows drives git through its own git.bat (git_cache.py
# hard-codes "git.bat"), which only exists after depot_tools' bootstrap has
# fetched its bundled Git + Python via CIPD. Run that bootstrap once if a
# fresh clone was used with DEPOT_TOOLS_UPDATE=0 (which skips it).
if (-not (Test-Path (Join-Path $DepotTools 'git.bat'))) {
    Log "bootstrapping depot_tools (bundled git/python via CIPD)..."
    & cmd.exe /c (Join-Path $DepotTools 'bootstrap\win_tools.bat')
    if (-not (Test-Path (Join-Path $DepotTools 'git.bat'))) { Die "depot_tools bootstrap did not produce git.bat" }
}
if (-not $env:DEPOT_TOOLS_UPDATE) { $env:DEPOT_TOOLS_UPDATE = '0' }

# ── Pin check (same rule as build-slice.sh -> angle-version.sh check) ─────
$LockPath = Join-Path $PkgDir 'config\angle.lock'
$lock = ConvertFrom-StringData -StringData ((Get-Content $LockPath | Where-Object { $_ -match '^[A-Z_]+=' }) -join "`n")
$headSha = (git -C $AngleSrc rev-parse HEAD).Trim()
$pos     = (git -C $AngleSrc rev-list HEAD --count).Trim()
if ((git -C $AngleSrc rev-parse --is-shallow-repository).Trim() -ne 'false') {
    Die "ANGLE checkout at $AngleSrc is shallow; the commit position (rev-list --count) would be wrong"
}
if (-not $SkipPinCheck) {
    if ($headSha -ne $lock.ANGLE_COMMIT) {
        Die "ANGLE checkout is at $headSha, pin is $($lock.ANGLE_COMMIT). Run 'git -C $AngleSrc checkout --detach $($lock.ANGLE_COMMIT)' then 'gclient sync', or 'make pin' to move the pin. (-SkipPinCheck to override.)"
    }
    if ($pos -ne $lock.ANGLE_COMMIT_POSITION) {
        Die "commit position $pos != pinned $($lock.ANGLE_COMMIT_POSITION)"
    }
}

$GnOut = Join-Path $AngleSrc "out\angle-pkg-$Slice"
$Stage = Join-Path $PkgDir "build\$Slice"

Log "ANGLE source : $AngleSrc (commit $($headSha.Substring(0,12)), position $pos)"
Log "depot_tools  : $DepotTools"
Log "GN output    : $GnOut"
Log "Staging dir  : $Stage"

# ── gn gen ───────────────────────────────────────────────────────────────
# The .gnargs file IS an args.gn (comments allowed), so copy it verbatim.
New-Item -ItemType Directory -Force $GnOut | Out-Null
Copy-Item $Config (Join-Path $GnOut 'args.gn') -Force
Push-Location $AngleSrc
try {
    Log "Running gn gen..."
    & gn.bat gen $GnOut
    if ($LASTEXITCODE -ne 0) { Die "gn gen failed (exit $LASTEXITCODE)" }
    Log "Effective backend/build args:"
    & gn.bat args $GnOut --list --short |
        Select-String 'angle_enable_|angle_build_tests|is_debug|is_clang|is_component_build|symbol_level|target_cpu|target_os' |
        ForEach-Object { Write-Host "    $($_.Line)" }

    # ── ninja ────────────────────────────────────────────────────────────
    # ANGLE's own ninja.exe, not depot_tools' autoninja/Siso wrapper (same
    # rule as build-slice.sh).
    Log "Building libEGL + libGLESv2 with $Ninja ..."
    & $Ninja -C $GnOut libEGL libGLESv2
    if ($LASTEXITCODE -ne 0) { Die "ninja failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

# ── Stage into build/<slice>/ ────────────────────────────────────────────
Remove-Item -Recurse -Force $Stage -ErrorAction Ignore
New-Item -ItemType Directory -Force $Stage | Out-Null
foreach ($f in 'libEGL.dll', 'libGLESv2.dll', 'libEGL.dll.lib', 'libGLESv2.dll.lib', 'libEGL.dll.pdb', 'libGLESv2.dll.pdb') {
    $src = Join-Path $GnOut $f
    if (-not (Test-Path $src)) { Die "expected build output not found: $src" }
    Copy-Item $src $Stage -Force
    Log "  staged: $f"
}
Log "Done. Slice staged at $Stage"
Get-ChildItem $Stage | Format-Table Name, @{n = 'Size'; e = { '{0:N0}' -f $_.Length } } -AutoSize
