#Requires -Version 5.1
<#
.SYNOPSIS
    Install roChassis's git hooks into this clone.

.DESCRIPTION
    .git/hooks is not tracked by git, so a committed hook does nothing until it
    is copied into place. Run this once per clone.

    Copies tools/hooks/* into .git/hooks/. Anything already there is backed up
    beside it as <name>.bak rather than overwritten - a hook you wrote yourself
    should not vanish because you ran a setup script.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\install-hooks.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$hooksDirectory = & git -C $root rev-parse --git-path hooks
if ($LASTEXITCODE -ne 0) {
    throw "Not a git repository: $root"
}
# rev-parse returns a path relative to the repo root for a normal clone.
if (-not [System.IO.Path]::IsPathRooted($hooksDirectory)) {
    $hooksDirectory = Join-Path $root $hooksDirectory
}
if (-not (Test-Path $hooksDirectory)) {
    [void] (New-Item -ItemType Directory -Force -Path $hooksDirectory)
}

$source = Join-Path $PSScriptRoot 'hooks'
$installed = 0

foreach ($hook in Get-ChildItem -Path $source -File) {
    $target = Join-Path $hooksDirectory $hook.Name

    if (Test-Path $target) {
        $existing = Get-Content -Path $target -Raw
        $incoming = Get-Content -Path $hook.FullName -Raw
        if ($existing -eq $incoming) {
            Write-Host "unchanged  $($hook.Name)"
            continue
        }
        $backup = "$target.bak"
        Copy-Item -Path $target -Destination $backup -Force
        Write-Host "backed up  $($hook.Name) -> $($hook.Name).bak" -ForegroundColor Yellow
    }

    # Written with LF and no BOM: Git for Windows runs hooks through sh, which
    # chokes on a CRLF shebang line with "bad interpreter" and on a BOM before
    # the '#!'. Set-Content would give both.
    $text = (Get-Content -Path $hook.FullName -Raw) -replace "`r`n", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($target, $text, $utf8NoBom)

    Write-Host "installed  $($hook.Name)" -ForegroundColor Green
    $installed++
}

Write-Host ''
Write-Host "$installed hook(s) installed into $hooksDirectory"
Write-Host 'Pushes now run tools\ci.ps1 first. Bypass once with: git push --no-verify'
