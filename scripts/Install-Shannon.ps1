#Requires -Version 5.1
# Install / update shannon-entropy on Windows (PowerShell + Python).
# Pure-Python path: sets SHANNON_SKIP_CORE=1 so pip never needs MSVC.
#
# PRIMARY (from a local GitHub clone — update = git pull + re-run):
#   powershell -ExecutionPolicy Bypass -File .\scripts\Install-Shannon.ps1 -Source path
#   powershell -ExecutionPolicy Bypass -File .\scripts\Install-Shannon.ps1 -Source path -Update
#
# Other modes:
#   powershell -File .\scripts\Install-Shannon.ps1                         # PyPI
#   powershell -File .\scripts\Install-Shannon.ps1 -Source git             # GitHub HEAD
#   powershell -File .\scripts\Install-Shannon.ps1 -Source 'git+https://github.com/LeBonhommePharma/Shannon.git'
#   powershell -File .\scripts\Install-Shannon.ps1 -Source path -SkipTests
#
# Delegates to scripts/shannon_installer.py (same contract as install_shannon.sh).

[CmdletBinding()]
param(
    [string]$Source = "pypi",
    [string]$PythonExe = "",
    [switch]$SkipTests,
    [switch]$Update,
    [switch]$ResolveOnly,
    [switch]$SmokeOnly
)

$ErrorActionPreference = "Stop"

function Get-PythonExe {
    param([string]$Preferred)
    if ($Preferred -and (Test-Path $Preferred)) {
        return $Preferred
    }
    if ($Preferred) {
        $cmd = Get-Command $Preferred -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    foreach ($name in @("python", "python3", "py")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            if ($name -eq "py") {
                return "py"
            }
            return $cmd.Source
        }
    }
    throw "Python 3.10+ not found. Install from https://www.python.org/downloads/"
}

function Invoke-Python {
    param(
        [string]$Exe,
        [string[]]$PyArgs
    )
    if ($Exe -eq "py") {
        & py -3 @PyArgs
    } else {
        & $Exe @PyArgs
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed ($LASTEXITCODE): $Exe $($PyArgs -join ' ')"
    }
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not (Test-Path (Join-Path $RepoRoot "pyproject.toml"))) {
    if (Test-Path (Join-Path (Get-Location) "pyproject.toml")) {
        $RepoRoot = (Get-Location).Path
    }
}

$Installer = Join-Path $RepoRoot "scripts\shannon_installer.py"
if (-not (Test-Path $Installer)) {
    throw "Missing installer: $Installer"
}

# Update default: prefer local clone when Source still pypi.
if ($Update -and ($Source -eq "pypi") -and (Test-Path (Join-Path $RepoRoot "pyproject.toml"))) {
    $Source = "path"
}

$py = Get-PythonExe -Preferred $PythonExe
Write-Host "==> Shannon Windows install via shannon_installer.py" -ForegroundColor Cyan
Write-Host "    Python: $py"
Write-Host "    Source: $Source"
Write-Host "    Repo:   $RepoRoot"

$pyArgs = @(
    $Installer,
    "--source", $Source,
    "--repo-root", $RepoRoot,
    "--python", $(if ($py -eq "py") { "py" } else { $py })
)

# When launcher is `py`, pass through as python executable name for child.
if ($py -eq "py") {
    $pyArgs = @(
        $Installer,
        "--source", $Source,
        "--repo-root", $RepoRoot
    )
}

if ($SkipTests) { $pyArgs += "--skip-tests" }
if ($Update) { $pyArgs += "--update" }
if ($ResolveOnly) { $pyArgs += "--resolve-only" }
if ($SmokeOnly) { $pyArgs += "--smoke-only" }

$env:SHANNON_SKIP_CORE = "1"
Invoke-Python -Exe $py -PyArgs $pyArgs
Write-Host "Shannon Windows install finished" -ForegroundColor Green
