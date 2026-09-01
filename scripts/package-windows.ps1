#Requires -Version 7
<#
.SYNOPSIS
  package-windows.ps1 — zip dist-windows-x64/ into release assets.

.DESCRIPTION
  Produces, in build/:
    angle-windows-x64-<tag>.zip           bin/ lib/ include/ LICENSE BUILD_INFO.txt
    angle-windows-x64-<tag>.zip.sha256    bare lowercase hex + LF (what the
                                          HAL's scripts/fetch-angle.sh parses)
    angle-windows-x64-<tag>-symbols.zip   pdb/
    angle-windows-x64-<tag>-symbols.zip.sha256

  Zips are FLAT (no top-level directory): consumers extract straight into
  their target directory. .NET's ZipFile is used rather than Compress-Archive
  because the latter historically wrote '\' path separators, which unzip on
  macOS/Linux does not treat as directories.

.PARAMETER Tag
  Release tag. Default: v2.1.<position> from config/angle.lock.
#>
[CmdletBinding()]
param(
    [string]$Slice = 'windows-x64',
    [string]$Tag = ''
)

$ErrorActionPreference = 'Stop'
$PkgDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Log([string]$m) { Write-Host "[package-windows] $m" -ForegroundColor Blue }
function Die([string]$m) { Write-Host "[package-windows error] $m" -ForegroundColor Red; exit 1 }

$Dist = Join-Path $PkgDir "dist-$Slice"
if (-not (Test-Path (Join-Path $Dist 'bin\libEGL.dll'))) { Die "$Dist is not assembled — run assemble-windows.ps1 first" }
if (-not $Tag) {
    $lock = ConvertFrom-StringData -StringData ((Get-Content (Join-Path $PkgDir 'config\angle.lock') | Where-Object { $_ -match '^[A-Z_]+=' }) -join "`n")
    $Tag = "v2.1.$($lock.ANGLE_COMMIT_POSITION)"
}
if ($Tag -notmatch '^v2\.1\.\d+(-\d+)?$') { Die "tag '$Tag' does not match v2.1.<position>[-N]" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Build = Join-Path $PkgDir 'build'
New-Item -ItemType Directory -Force $Build | Out-Null

function New-FlatZip([string]$srcDir, [string]$zip) {
    Remove-Item $zip -Force -ErrorAction Ignore
    # includeBaseDirectory=$false => entries are relative to $srcDir (flat);
    # .NET writes '/' separators.
    [IO.Compression.ZipFile]::CreateFromDirectory($srcDir, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
}
function Write-Sha256([string]$file) {
    $h = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    [IO.File]::WriteAllText("$file.sha256", "$h`n", [Text.UTF8Encoding]::new($false))
    return $h
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) "angle-package-$PID"
$main = Join-Path $tmpRoot 'main'
$sym  = Join-Path $tmpRoot 'symbols'
Remove-Item -Recurse -Force $tmpRoot -ErrorAction Ignore
try {
    New-Item -ItemType Directory -Force $main, (Join-Path $sym 'pdb') | Out-Null
    # Main zip: everything except pdb/.
    Get-ChildItem $Dist | Where-Object { $_.Name -ne 'pdb' } | ForEach-Object { Copy-Item -Recurse $_.FullName (Join-Path $main $_.Name) }
    Copy-Item (Join-Path $Dist 'pdb\*') (Join-Path $sym 'pdb')

    $mainZip = Join-Path $Build "angle-$Slice-$Tag.zip"
    $symZip  = Join-Path $Build "angle-$Slice-$Tag-symbols.zip"
    New-FlatZip $main $mainZip
    New-FlatZip $sym  $symZip
    $h1 = Write-Sha256 $mainZip
    $h2 = Write-Sha256 $symZip
    Log ("{0}  {1:N0} bytes  sha256 {2}" -f (Split-Path $mainZip -Leaf), (Get-Item $mainZip).Length, $h1)
    Log ("{0}  {1:N0} bytes  sha256 {2}" -f (Split-Path $symZip -Leaf), (Get-Item $symZip).Length, $h2)
    # Show the main zip's entries for the log (verifies flat layout + '/' separators).
    $z = [IO.Compression.ZipFile]::OpenRead($mainZip)
    try { $z.Entries | ForEach-Object { Write-Host "    $($_.FullName)" } } finally { $z.Dispose() }
} finally {
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction Ignore
}
