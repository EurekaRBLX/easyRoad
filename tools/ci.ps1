#Requires -Version 5.1
<#
.SYNOPSIS
    Every check that has to pass before this plugin is pushed. Runs locally on
    Windows.

.DESCRIPTION
    easyRoad runs a comparable set as a GitHub Actions job on ubuntu-latest.
    The easy*/ro* plugins run it here instead, on the machine they are
    actually developed on, for two reasons:

      * The Luau toolchain is already on this machine (tools\luau, which every
        repo in the family keeps and gitignores), so a hosted runner would
        spend most of its wall time downloading a compiler that is on disk.
      * The check that matters most - "is dist/ stale?" - is only useful
        BEFORE a push. Learning from a red tick that you pushed a stale
        artifact is learning too late, because dist/ is what anyone installing
        without a toolchain actually gets.

    Wire it to a git pre-push hook with tools\install-hooks.ps1 and a stale
    dist cannot leave the machine.

    THIS SCRIPT IS IDENTICAL IN EVERY REPO IN THE FAMILY. It derives the
    plugin name from the folder and discovers which steps this repo supports,
    so a repo without a linter or a test harness reports those as skipped
    rather than failing, and gains them with no edit here. Copy it across
    verbatim; do not fork it per plugin.

.PARAMETER Luau
    Directory holding luau.exe and luau-compile.exe. Otherwise: $env:<NAME>_LUAU,
    this repo's own tools\luau, a sibling checkout, then PATH. Populate
    tools\luau with tools\fetch-luau.ps1.

.PARAMETER SkipDist
    Skip the dist/ freshness check. For a quick inner-loop run only - never
    for a push.

.PARAMETER SkipPreviews
    Skip the headless previews. Worth having because they are not all cheap:
    easyRoad's suite is a full geometry port and takes about 13 minutes on
    this machine, which is far too long to sit in front of on every push. The
    panel previews in roAnimate and roChassis take under a second, so leave
    them on there.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\ci.ps1
#>
[CmdletBinding()]
param(
    [string] $Luau,
    [switch] $SkipDist,
    [switch] $SkipPreviews
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$plugin = Split-Path -Leaf $root
$failures = New-Object System.Collections.ArrayList

function Write-Step {
    param([string] $Name)
    Write-Host ''
    Write-Host "==> $Name" -ForegroundColor Cyan
}

function Add-Failure {
    param([string] $Name, [string] $Hint)
    [void] $failures.Add([pscustomobject]@{ Name = $Name; Hint = $Hint })
    Write-Host "FAIL  $Name" -ForegroundColor Red
}

function Write-Pass {
    param([string] $Name)
    Write-Host "ok    $Name" -ForegroundColor Green
}

function Write-Skip {
    param([string] $Name, [string] $Why)
    Write-Host "skip  $Name - $Why" -ForegroundColor Yellow
}

# Tooling ---------------------------------------------------------------------

function Resolve-Python {
    foreach ($name in @('python', 'python3', 'py')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }
    throw "No Python interpreter found. Install Python 3 and put it on PATH."
}

# Both binaries have to come from the SAME directory. A luau.exe from one
# release running a chunk that luau-compile.exe from another accepted is a
# genuinely confusing way to lose an afternoon.
function Resolve-LuauDirectory {
    param([string] $Explicit)

    $candidates = New-Object System.Collections.ArrayList
    if ($Explicit) { [void] $candidates.Add($Explicit) }

    $fromEnvironment = [Environment]::GetEnvironmentVariable(($plugin.ToUpper() + '_LUAU'))
    if ($fromEnvironment) { [void] $candidates.Add($fromEnvironment) }

    # This repo's OWN copy comes first. easyRail and easyLight each keep one
    # and each gitignores it, so a per-repo tools\luau is the family
    # convention already - it makes a clone self-sufficient instead of
    # depending on a sibling checkout that may not exist. Populate it with
    # tools\fetch-luau.ps1.
    [void] $candidates.Add((Join-Path $root 'tools\luau'))

    # Sibling checkouts, for a clone that has not fetched one yet.
    foreach ($sibling in @('easyRail', 'easyLight', 'easyRoad', 'roAnimate', 'roChassis')) {
        [void] $candidates.Add((Join-Path $root "..\$sibling\tools\luau"))
        [void] $candidates.Add((Join-Path $root "..\..\$sibling\tools\luau"))
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path $candidate)) { continue }
        $interpreter = Join-Path $candidate 'luau.exe'
        $compiler = Join-Path $candidate 'luau-compile.exe'
        if ((Test-Path $interpreter) -and (Test-Path $compiler)) {
            return (Resolve-Path $candidate).Path
        }
    }

    $onPath = Get-Command 'luau-compile' -ErrorAction SilentlyContinue
    if ($onPath) {
        $directory = Split-Path -Parent $onPath.Source
        if (Test-Path (Join-Path $directory 'luau.exe')) {
            return $directory
        }
    }

    throw @"
Could not find luau.exe and luau-compile.exe.

Populate this repo's own copy:

    powershell -ExecutionPolicy Bypass -File tools\fetch-luau.ps1

or, with no network but a sibling checkout already set up:

    powershell -ExecutionPolicy Bypass -File tools\fetch-luau.ps1 -FromSibling

tools\luau is gitignored, so it stays local to this clone. You can also pass
-Luau <directory> or set `$env:$($plugin.ToUpper())_LUAU.
"@
}

$python = Resolve-Python
$luauDirectory = Resolve-LuauDirectory -Explicit $Luau
$luauExe = Join-Path $luauDirectory 'luau.exe'
$luauCompileExe = Join-Path $luauDirectory 'luau-compile.exe'

Write-Host "$plugin checks" -ForegroundColor White
Write-Host "  python : $python"
Write-Host "  luau   : $luauDirectory"

# 1. Static checks the parser cannot make ---------------------------------------
#
# The compiler parses each file in isolation, so it is blind to a module used
# but never required and to a `local function` called above its declaration.
# Both are runtime faults. Where a repo has a linter, it runs alongside the
# compiler, not instead of it.

$lint = Join-Path $root 'tools\lint.py'
if (Test-Path $lint) {
    Write-Step 'Lint (requires, declaration order, ambiguous calls)'
    & $python $lint
    if ($LASTEXITCODE -ne 0) {
        Add-Failure 'lint' 'See the messages above; each names a file and line.'
    } else {
        Write-Pass 'lint'
    }
} else {
    Write-Step 'Lint (none in this repo)'
    Write-Skip 'lint' 'no tools\lint.py'
}

# 2. Every module parses ---------------------------------------------------------
#
# Cheap and total, and it catches the whole class of "this never even loaded in
# Studio" breakage. One invocation over the whole file list: luau-compile takes
# a file list, and `--null` compiles and discards the bytecode rather than
# spraying it at the console the way `--binary` would.

Write-Step 'Parse every module'
$sources = @()
foreach ($directory in @('src')) {
    $path = Join-Path $root $directory
    if (Test-Path $path) {
        $sources += @(Get-ChildItem -Path $path -Recurse -Include '*.lua', '*.luau' |
            ForEach-Object { $_.FullName })
    }
}
foreach ($loader in @('loader.server.lua', 'loader.server.luau')) {
    $path = Join-Path $root $loader
    if (Test-Path $path) { $sources += $path }
}

if ($sources.Count -eq 0) {
    Add-Failure 'parse' 'No source files found to parse.'
} else {
    & $luauCompileExe --null $sources
    if ($LASTEXITCODE -ne 0) {
        Add-Failure 'parse' 'A module failed to parse - it would not load in Studio at all.'
    } else {
        Write-Pass "parse ($($sources.Count) files)"
    }
}

# 3. Behavioural checks -----------------------------------------------------------
#
# Runs the real src/ modules headlessly over Roblox stand-ins. Skipped where a
# repo has no harness yet, so adding one turns this on with no edit.

$testRunner = Join-Path $root 'tools\test\run.py'
if (Test-Path $testRunner) {
    Write-Step 'Behavioural checks'
    & $python $testRunner $luauExe $luauCompileExe
    if ($LASTEXITCODE -ne 0) {
        Add-Failure 'tests' 'See the FAIL lines above.'
    } else {
        Write-Pass 'tests'
    }
} else {
    Write-Step 'Behavioural checks (none in this repo)'
    Write-Skip 'tests' 'no tools\test\run.py'
}

# 4. Headless previews ------------------------------------------------------------
#
# Renders and scans whatever this repo previews - a panel, or geometry. The
# only automated look at anything Studio would otherwise have to show.

$previewRunner = Join-Path $root 'tools\preview\validate.py'
if ($SkipPreviews) {
    Write-Step 'Headless previews (skipped)'
    Write-Skip 'previews' 'requested with -SkipPreviews'
} elseif (Test-Path $previewRunner) {
    Write-Step 'Headless previews'
    & $python $previewRunner
    if ($LASTEXITCODE -ne 0) {
        Add-Failure 'previews' 'A preview scan failed; see above.'
    } else {
        Write-Pass 'previews'
    }
} else {
    Write-Step 'Headless previews (none in this repo)'
    Write-Skip 'previews' 'no tools\preview\validate.py'
}

# 5. dist/ is not stale -------------------------------------------------------------
#
# dist/*.rbxmx is committed so the plugin installs with no toolchain at all,
# which means it is what most people actually run. A stale one is worse than
# none: it looks installed and behaves like an old build.
#
# Some repos build a second OSS-licensed artifact from the same source. Both
# are rebuilt when the build script supports it, because checking only one
# leaves the other free to rot unnoticed.

if ($SkipDist) {
    Write-Step 'dist/ (skipped)'
    Write-Skip 'dist' 'do not push with this skipped'
} else {
    Write-Step 'dist/ is up to date'
    $builder = Join-Path $root 'tools\build_rbxmx.py'
    if (-not (Test-Path $builder)) {
        Write-Skip 'dist' 'no tools\build_rbxmx.py'
    } else {
        $builderText = Get-Content $builder -Raw
        $ok = $true

        & $python $builder
        if ($LASTEXITCODE -ne 0) { $ok = $false }

        if ($ok -and $builderText -match '--license') {
            & $python $builder --license oss
            if ($LASTEXITCODE -ne 0) { $ok = $false }
        }

        if (-not $ok) {
            Add-Failure 'dist build' 'tools\build_rbxmx.py failed.'
        } else {
            & git -C $root diff --exit-code --quiet -- 'dist'
            if ($LASTEXITCODE -ne 0) {
                Add-Failure 'dist stale' 'dist/ drifted from src\. It has just been rebuilt - commit it.'
            } else {
                Write-Pass 'dist up to date'
            }
        }
    }
}

# Result -----------------------------------------------------------------------------

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) failed:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host ("  - {0}: {1}" -f $failure.Name, $failure.Hint) -ForegroundColor Red
    }
    exit 1
}

Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
