#Requires -Version 7
<#
.SYNOPSIS
  sign-windows.ps1 — optional Authenticode signing of dist-windows-x64/bin/*.dll.

.DESCRIPTION
  Windows analogue of sign-framework.sh. Signs with signtool.exe when a PFX is
  supplied through the environment:

    WINDOWS_CODESIGN_PFX_BASE64    base64 of the .pfx
    WINDOWS_CODESIGN_PFX_PASSWORD  its password
    WINDOWS_CODESIGN_TSA           RFC 3161 timestamp URL
                                   (default http://timestamp.digicert.com)

  Without them it is a no-op: the DLLs ship unsigned and BUILD_INFO.txt keeps
  "Signing: unsigned". There is no ad-hoc signing on Windows.
#>
[CmdletBinding()]
param([string]$Slice = 'windows-x64')

$ErrorActionPreference = 'Stop'
$PkgDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Log([string]$m) { Write-Host "[sign-windows] $m" -ForegroundColor Blue }
function Die([string]$m) { Write-Host "[sign-windows error] $m" -ForegroundColor Red; exit 1 }

$Dist = Join-Path $PkgDir "dist-$Slice"
$dlls = @((Join-Path $Dist 'bin\libEGL.dll'), (Join-Path $Dist 'bin\libGLESv2.dll'))
foreach ($d in $dlls) { if (-not (Test-Path $d)) { Die "missing $d — run assemble-windows.ps1 first" } }

if (-not $env:WINDOWS_CODESIGN_PFX_BASE64 -or -not $env:WINDOWS_CODESIGN_PFX_PASSWORD) {
    Log "no WINDOWS_CODESIGN_PFX_BASE64 / _PASSWORD in the environment — leaving the DLLs unsigned"
    exit 0
}

$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction Ignore |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { Die "signtool.exe not found under the Windows SDK" }
$tsa = if ($env:WINDOWS_CODESIGN_TSA) { $env:WINDOWS_CODESIGN_TSA } else { 'http://timestamp.digicert.com' }

$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$pfx = Join-Path $tmp "angle-codesign-$PID.pfx"
try {
    [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:WINDOWS_CODESIGN_PFX_BASE64))
    & $signtool.FullName sign /fd SHA256 /td SHA256 /tr $tsa /f $pfx /p $env:WINDOWS_CODESIGN_PFX_PASSWORD @dlls
    if ($LASTEXITCODE -ne 0) { Die "signtool failed (exit $LASTEXITCODE)" }
    $sig = Get-AuthenticodeSignature $dlls[1]
    if ($sig.Status -ne 'Valid') { Die "signature status after signing: $($sig.Status)" }
    $line = "Signing:            Authenticode ($($sig.SignerCertificate.Subject); thumbprint $($sig.SignerCertificate.Thumbprint); timestamped via $tsa)"
    $info = Join-Path $Dist 'BUILD_INFO.txt'
    $text = [IO.File]::ReadAllText($info) -replace '(?m)^Signing:.*$', $line
    [IO.File]::WriteAllText($info, $text, [Text.UTF8Encoding]::new($false))
    Log "signed: $($sig.SignerCertificate.Subject)"
} finally {
    Remove-Item $pfx -Force -ErrorAction Ignore
}
