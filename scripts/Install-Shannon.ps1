#Requires -Version 5.1
<#
.SYNOPSIS
  Install shannon-entropy on Windows (PowerShell + Python).

.DESCRIPTION
  Pure-Python install path — no bash, no C++ toolchain required.
  Uses SHANNON_SKIP_CORE=1 so pip never fails for missing MSVC.

.PARAMETER Source
  Install source: "pypi" (default), "path" (local repo), or an explicit path/URL.

.PARAMETER Python
  Python launcher. Default: py -3 if available, else python.

.PARAMETER SkipTests
  Skip post-install smoke tests.

.EXAMPLE
  # From a clone (recommended for contributors):
  powershell -ExecutionPolicy Bypass -File .\scripts\Install-Shannon.ps1 -Source path

.EXAMPLE
  # From PyPI once 2.1.0+ is published:
  powershell -ExecutionPolicy Bypass -File .\scripts\Install-Shannon.ps1
#>
[CmdletBinding()]
param(
    [string]$Source = "pypi",
    [string]$Python = "",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not (Test-Path (Join-Path $RepoRoot "pyproject.toml"))) {
    # Invoked from repo root: scripts\Install-Shannon.ps1
    if (Test-Path ".\pyproject.toml") {
        $RepoRoot = (Get-Location).Path
    }
}

function Resolve-Python {
    param([string]$Preferred)
    if ($Preferred) {
        return $Preferred
    }
    if (Get-Command py -ErrorAction SilentlyContinue) {
        return "py -3"
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        return "python"
    }
    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        return "python3"
    }
    throw "Python 3.10+ not found. Install from https://www.python.org/downloads/ and ensure 'py' or 'python' is on PATH."
}

function Invoke-Py {
    param([string]$PyCmd, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $parts = $PyCmd -split "\s+", 2
    if ($parts.Count -eq 2) {
        & $parts[0] $parts[1].Split(" ") @Args
    } else {
        & $parts[0] @Args
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $PyCmd $($Args -join ' ')"
    }
}

Write-Host "==> Shannon Windows install (pure-Python)" -ForegroundColor Cyan
$py = Resolve-Python -Preferred $Python
Write-Host "    Python: $py"

# Version probe
$verOut = & {
    $parts = $py -split "\s+", 2
    if ($parts.Count -eq 2) {
        & $parts[0] $parts[1].Split(" ") -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}'); raise SystemExit(0 if sys.version_info >= (3,10) else 1)"
    } else {
        & $parts[0] -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}'); raise SystemExit(0 if sys.version_info >= (3,10) else 1)"
    }
}
if ($LASTEXITCODE -ne 0) {
    throw "Python 3.10+ required (got: $verOut)"
}
Write-Host "    Version: $verOut"

$env:SHANNON_SKIP_CORE = "1"
Write-Host "    SHANNON_SKIP_CORE=1 (pure-Python; no MSVC required)"

Invoke-Py $py -m pip install --upgrade pip setuptools wheel

$target = $Source
if ($Source -eq "pypi") {
    $target = "shannon-entropy"
} elseif ($Source -eq "path") {
    $target = $RepoRoot
    if (-not (Test-Path (Join-Path $target "pyproject.toml"))) {
        throw "Local path install requires the Shannon repo root (missing pyproject.toml under $target)"
    }
}

Write-Host "==> pip install $target"
if ($Source -eq "path") {
    Invoke-Py $py -m pip install -e "$target"
} else {
    Invoke-Py $py -m pip install "$target"
}

if ($SkipTests) {
    Write-Host "✓ Install complete (tests skipped)" -ForegroundColor Green
    exit 0
}

Write-Host "==> Smoke tests"
$smoke = @'
import sys
import numpy as np
import shannon
from shannon import ShannonCollapseDetector, shannon_entropy_from_probs

assert shannon.__version__, shannon.__version__
print("shannon", shannon.__version__, "_HAS_CORE=", getattr(shannon, "_HAS_CORE", None))
h = shannon_entropy_from_probs(np.array([0.25, 0.25, 0.25, 0.25], dtype=float))
assert abs(h - 2.0) < 1e-9, h
_ = ShannonCollapseDetector()
print("entropy_smoke_ok", h)
print("python", sys.version.split()[0])
'@
Invoke-Py $py -c $smoke

Write-Host "==> shannon-monitor --help"
$parts = $py -split "\s+", 2
if ($parts.Count -eq 2) {
    & $parts[0] $parts[1].Split(" ") -m shannon.cli --help 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        # Entry point may be on Scripts PATH
        if (Get-Command shannon-monitor -ErrorAction SilentlyContinue) {
            & shannon-monitor --help 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "shannon-monitor --help failed" }
        } else {
            throw "shannon-monitor not available"
        }
    }
} else {
    & $parts[0] -m shannon.cli --help 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        if (Get-Command shannon-monitor -ErrorAction SilentlyContinue) {
            & shannon-monitor --help 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "shannon-monitor --help failed" }
        } else {
            throw "shannon-monitor not available"
        }
    }
}

Write-Host "✓ Shannon installed and smoke-tested on Windows PowerShell" -ForegroundColor Green
