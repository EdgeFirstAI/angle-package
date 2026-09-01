#Requires -Version 7
<#
.SYNOPSIS
  verify-windows.ps1 — validate dist-windows-x64/ the way verify.sh validates dist/.

.DESCRIPTION
  Checks:
    1. Layout: DLLs, import libs, headers, LICENSE, BUILD_INFO.txt present.
    2. Both DLLs are x64 PE images.
    3. Imports: each DLL depends only on Windows system DLLs (+ libGLESv2 for
       libEGL). vcruntime*/msvcp*/ucrtbase would mean the dynamic CRT leaked
       in — the package promises "no VC++ redistributable required".
    4. Authenticode status (unsigned is a warning unless -RequireSignature).
    5. Runtime probe (scripts/windows/angle_probe.c, compiled with cl twice:
       LoadLibrary path and import-lib path): brings up an ANGLE D3D11 display
       — hardware by default, WARP with -Warp (CI runners have no GPU) — and
       an OpenGL ES 3 context, prints GL_RENDERER / GL_VERSION, asserts the
       renderer is Direct3D11 and, with -ExpectPosition, that GL_VERSION
       carries "ANGLE 2.1.<position>" (catches shallow-clone builds).

  Needs cl.exe + dumpbin.exe: run from a Visual Studio developer shell, or let
  the script import one (it looks for Launch-VsDevShell.ps1 via vswhere).

.PARAMETER Warp
  Use the Microsoft Basic Render Driver (software) for the runtime probe.
.PARAMETER ExpectPosition
  ANGLE commit position the built binary must report. Default: from
  config/angle.lock.
.PARAMETER RequireSignature
  Fail (instead of warn) when the DLLs are unsigned.
#>
[CmdletBinding()]
param(
    [string]$Slice = 'windows-x64',
    [string]$Dist = '',
    [switch]$Warp,
    [string]$ExpectPosition = '',
    [switch]$RequireSignature
)

$ErrorActionPreference = 'Stop'
$PkgDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Dist) { $Dist = Join-Path $PkgDir "dist-$Slice" }
function Log([string]$m)  { Write-Host "[verify-windows] $m" -ForegroundColor Blue }
function Warn([string]$m) { Write-Host "[verify-windows WARN] $m" -ForegroundColor Yellow }
$script:Failures = 0
function Fail([string]$m) { Write-Host "[verify-windows FAIL] $m" -ForegroundColor Red; $script:Failures++ }

if (-not $ExpectPosition) {
    $lockPath = Join-Path $PkgDir 'config\angle.lock'
    if (Test-Path $lockPath) {
        $lock = ConvertFrom-StringData -StringData ((Get-Content $lockPath | Where-Object { $_ -match '^[A-Z_]+=' }) -join "`n")
        $ExpectPosition = $lock.ANGLE_COMMIT_POSITION
    }
}

# ── 1. Layout ────────────────────────────────────────────────────────────
Log "=== Layout ($Dist) ==="
$required = @(
    'bin\libEGL.dll', 'bin\libGLESv2.dll',
    'lib\libEGL.dll.lib', 'lib\libGLESv2.dll.lib',
    'include\EGL\egl.h', 'include\EGL\eglext.h', 'include\EGL\eglext_angle.h', 'include\EGL\eglplatform.h',
    'include\GLES2\gl2.h', 'include\GLES2\gl2ext.h', 'include\GLES3\gl3.h', 'include\GLES3\gl31.h',
    'include\KHR\khrplatform.h', 'LICENSE', 'BUILD_INFO.txt'
)
foreach ($f in $required) {
    if (Test-Path (Join-Path $Dist $f)) { Log "  ok: $f" } else { Fail "missing $f" }
}

# ── 2. PE machine ────────────────────────────────────────────────────────
Log "=== PE architecture ==="
foreach ($dll in 'libEGL.dll', 'libGLESv2.dll') {
    $p = Join-Path $Dist "bin\$dll"
    if (-not (Test-Path $p)) { continue }
    $fs = [IO.File]::OpenRead($p)
    try {
        $pe = [System.Reflection.PortableExecutable.PEReader]::new($fs)
        try {
            $m = $pe.PEHeaders.CoffHeader.Machine
            if ("$m" -eq 'Amd64') { Log "  $dll : $m" } else { Fail "$dll is $m, expected Amd64" }
        } finally { $pe.Dispose() }
    } finally { $fs.Dispose() }
}

# ── Toolchain: cl + dumpbin (import a VS dev shell if needed) ────────────
if (-not (Get-Command cl.exe -ErrorAction Ignore)) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $vsPath = if (Test-Path $vswhere) { & $vswhere -latest -products * -property installationPath 2>$null | Select-Object -First 1 } else { $null }
    $devShell = if ($vsPath) { Join-Path $vsPath 'Common7\Tools\Launch-VsDevShell.ps1' } else { $null }
    if ($devShell -and (Test-Path $devShell)) {
        Log "importing Visual Studio developer environment from $devShell"
        # Launch-VsDevShell.ps1 expects vswhere.exe on PATH.
        $env:PATH = "$(Split-Path $vswhere -Parent);$env:PATH"
        & $devShell -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null
    }
}
$haveCl = [bool](Get-Command cl.exe -ErrorAction Ignore)
$haveDumpbin = [bool](Get-Command dumpbin.exe -ErrorAction Ignore)

# ── 3. Imports ───────────────────────────────────────────────────────────
Log "=== Imports (dumpbin /dependents) ==="
# d3d9.dll: ANGLE's D3D11 backend imports it for D3DPERF_* debug markers; it is
# a Windows system DLL like d3d11/dxgi.
$allow = '^(kernel32|kernelbase|user32|gdi32|advapi32|shell32|ole32|oleaut32|shlwapi|version|winmm|ws2_32|dbghelp|bcrypt|ntdll|dwmapi|setupapi|synchronization|d3d9|d3d11|dxgi|d3dcompiler_47|libglesv2|api-ms-win-[a-z0-9-]+|ext-ms-win-[a-z0-9-]+)\.dll$'
if ($haveDumpbin) {
    foreach ($dll in 'libEGL.dll', 'libGLESv2.dll') {
        $p = Join-Path $Dist "bin\$dll"
        if (-not (Test-Path $p)) { continue }
        $deps = (& dumpbin.exe /nologo /dependents $p) | Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim().ToLower() }
        Log "  $dll imports: $($deps -join ', ')"
        foreach ($d in $deps) {
            if ($d -match '^(vcruntime|msvcp|ucrtbase)') { Fail "$dll links the dynamic CRT ($d); expected a static CRT (is_component_build=false)" }
            elseif ($d -notmatch $allow) { Fail "$dll imports non-system DLL $d" }
        }
    }
} else {
    Warn "dumpbin.exe not found (not in a VS developer shell); skipping the import allowlist"
}

# ── 4. Authenticode ──────────────────────────────────────────────────────
Log "=== Authenticode ==="
foreach ($dll in 'libEGL.dll', 'libGLESv2.dll') {
    $p = Join-Path $Dist "bin\$dll"
    if (-not (Test-Path $p)) { continue }
    $s = Get-AuthenticodeSignature $p
    switch ("$($s.Status)") {
        'Valid'     { Log "  $dll signed by $($s.SignerCertificate.Subject)" }
        'NotSigned' { if ($RequireSignature) { Fail "$dll is unsigned" } else { Warn "$dll is unsigned (expected without a code-signing certificate)" } }
        default     { Fail "$dll signature status: $($s.Status)" }
    }
}

# ── 5. Runtime probe ─────────────────────────────────────────────────────
Log "=== Runtime probe ($(if ($Warp) { 'WARP' } else { 'hardware' })) ==="
if (-not $haveCl) {
    Fail "cl.exe not available; cannot build the runtime probe (run from a Visual Studio developer shell)"
} else {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "angle-probe-$PID"
    Remove-Item -Recurse -Force $tmp -ErrorAction Ignore
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $src = Join-Path $PkgDir 'scripts\windows\angle_probe.c'
        $inc = Join-Path $Dist 'include'
        Push-Location $tmp
        try {
            & cl.exe /nologo /W3 /I $inc $src /Fe:angle_probe.exe /link kernel32.lib | Out-Host
            if ($LASTEXITCODE -ne 0) { Fail "probe (dynamic) failed to compile" }
            & cl.exe /nologo /W3 /DPROBE_STATIC_LINK /I $inc $src /Fe:angle_probe_static.exe /link (Join-Path $Dist 'lib\libEGL.dll.lib') (Join-Path $Dist 'lib\libGLESv2.dll.lib') | Out-Host
            if ($LASTEXITCODE -ne 0) { Fail "probe (import-lib) failed to compile" }
        } finally { Pop-Location }

        $args_ = @((Join-Path $Dist 'bin')); if ($Warp) { $args_ += '--warp' }
        if (Test-Path (Join-Path $tmp 'angle_probe.exe')) {
            $out = & (Join-Path $tmp 'angle_probe.exe') @args_ 2>&1
            $rc = $LASTEXITCODE
            $out | ForEach-Object { Write-Host "    $_" }
            if ($rc -ne 0) { Fail "dynamic-load probe exited $rc" }
            $rend = ($out | Where-Object { "$_" -like 'GL_RENDERER=*' } | Select-Object -First 1)
            $ver  = ($out | Where-Object { "$_" -like 'GL_VERSION=*' }  | Select-Object -First 1)
            if ("$rend" -notmatch 'Direct3D11') { Fail "renderer is not Direct3D 11: $rend" }
            if ($Warp -and "$rend" -notmatch 'Basic Render Driver') { Warn "-Warp requested but renderer is: $rend" }
            if ($ExpectPosition -and "$ver" -notmatch "ANGLE 2\.1\.$ExpectPosition\b") { Fail "GL_VERSION '$ver' lacks 'ANGLE 2.1.$ExpectPosition' (wrong pin or shallow clone)" }
        }
        if (Test-Path (Join-Path $tmp 'angle_probe_static.exe')) {
            # The import-lib build loads libEGL.dll from the exe's directory.
            Copy-Item (Join-Path $Dist 'bin\*.dll') $tmp
            $out2 = & (Join-Path $tmp 'angle_probe_static.exe') $tmp $(if ($Warp) { '--warp' }) 2>&1
            if ($LASTEXITCODE -ne 0) { $out2 | ForEach-Object { Write-Host "    $_" }; Fail "import-lib probe exited $LASTEXITCODE" }
            else { Log "  import-lib probe ok: $(($out2 | Where-Object { "$_" -like 'GL_RENDERER=*' }))" }
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction Ignore
    }
}

if ($script:Failures -gt 0) { Write-Host "[verify-windows] $($script:Failures) check(s) FAILED" -ForegroundColor Red; exit 1 }
Log "All checks passed."
