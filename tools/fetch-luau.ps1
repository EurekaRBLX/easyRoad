#Requires -Version 5.1
<#
.SYNOPSIS
    Put a Luau toolchain in this repo's tools\luau, so the checks run on a
    fresh clone with nothing else installed.

.DESCRIPTION
    Every plugin in this family keeps its own tools\luau, and every one of
    them GITIGNORES it - 9.7MB of platform-specific binaries has no business
    in git history, where it can never be diffed and never really be deleted.
    That leaves a gap this script fills: the directory is required, ignored,
    and until now populated by hand, so a fresh clone had no way to get one
    except copying from a sibling checkout that may not exist.

    Downloads the Luau release archive from GitHub and extracts luau.exe,
    luau-compile.exe, luau-analyze.exe and luau-ast.exe into tools\luau.

    If a sibling checkout already has them, -FromSibling copies instead, which
    is faster and works with no network at all.

.PARAMETER Version
    Release tag to fetch. Defaults to whatever GitHub reports as latest.

.PARAMETER FromSibling
    Copy from a sibling repo's tools\luau instead of downloading. No network
    needed. Point it somewhere specific with -SiblingPath.

.PARAMETER SiblingPath
    An explicit directory to copy from. Implies -FromSibling.

.PARAMETER Force
    Overwrite an existing tools\luau.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\fetch-luau.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\fetch-luau.ps1 -FromSibling
#>
[CmdletBinding()]
param(
    [string] $Version,
    [switch] $FromSibling,
    [string] $SiblingPath,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root 'tools\luau'

$needed = @('luau.exe', 'luau-compile.exe')
$wanted = @('luau.exe', 'luau-compile.exe', 'luau-analyze.exe', 'luau-ast.exe')

function Test-Complete {
    param([string] $Directory)
    if (-not (Test-Path $Directory)) { return $false }
    foreach ($name in $needed) {
        if (-not (Test-Path (Join-Path $Directory $name))) { return $false }
    }
    return $true
}

if ((Test-Complete $target) -and -not $Force) {
    Write-Host "tools\luau already has a toolchain. Use -Force to replace it." -ForegroundColor Green
    Get-ChildItem $target -Filter *.exe | ForEach-Object { Write-Host "  $($_.Name)" }
    exit 0
}

[void] (New-Item -ItemType Directory -Force -Path $target)

# Sibling copy ------------------------------------------------------------------

if ($FromSibling -or $SiblingPath) {
    $candidates = New-Object System.Collections.ArrayList
    if ($SiblingPath) {
        [void] $candidates.Add($SiblingPath)
    } else {
        foreach ($sibling in @('easyRail', 'easyLight', 'easyRoad', 'roAnimate', 'roChassis')) {
            [void] $candidates.Add((Join-Path $root "..\$sibling\tools\luau"))
            [void] $candidates.Add((Join-Path $root "..\..\$sibling\tools\luau"))
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Complete $candidate) {
            Write-Host "Copying from $((Resolve-Path $candidate).Path)"
            Get-ChildItem $candidate -Filter *.exe | ForEach-Object {
                Copy-Item $_.FullName -Destination $target -Force
                Write-Host "  $($_.Name)"
            }
            Write-Host "Done." -ForegroundColor Green
            exit 0
        }
    }
    throw "No sibling checkout with a populated tools\luau was found."
}

# Download ----------------------------------------------------------------------

# GitHub's API needs a User-Agent, and Windows PowerShell 5.1 still defaults to
# TLS 1.0, which github.com refuses outright.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ 'User-Agent' = 'roChassis-fetch-luau' }

if (-not $Version) {
    Write-Host 'Asking GitHub for the latest Luau release...'
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/luau-lang/luau/releases/latest' -Headers $headers
    $Version = $release.tag_name
}
Write-Host "Fetching Luau $Version"

$archive = Join-Path $env:TEMP "luau-windows-$Version.zip"
$url = "https://github.com/luau-lang/luau/releases/download/$Version/luau-windows.zip"

Invoke-WebRequest -Uri $url -OutFile $archive -Headers $headers
Write-Host "  downloaded $([math]::Round((Get-Item $archive).Length / 1MB, 1)) MB"

$staging = Join-Path $env:TEMP "luau-windows-$Version"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
Expand-Archive -Path $archive -DestinationPath $staging -Force

$copied = 0
foreach ($name in $wanted) {
    $found = Get-ChildItem $staging -Filter $name -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        Copy-Item $found.FullName -Destination $target -Force
        Write-Host "  $name"
        $copied++
    }
}

Remove-Item $staging -Recurse -Force
Remove-Item $archive -Force

if (-not (Test-Complete $target)) {
    throw "Extracted $copied file(s) but tools\luau is still missing one of: $($needed -join ', ')"
}

Write-Host "Done. tools\luau is gitignored - it stays local to this clone." -ForegroundColor Green
