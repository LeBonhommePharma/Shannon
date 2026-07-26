#Requires -Version 5.1
# Install shannon-entropy on Windows (PowerShell + Python).
# Pure-Python path: sets SHANNON_SKIP_CORE=1 so pip never needs MSVC.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\Install-Shannon.ps1 -Source path
#   powershell -ExecutionPolicy Bypass -File .\scripts\Install-Shannon.ps1
#
[CmdletBinding()]
param(
    [string]$Source = "pypi",
    [string]$PythonExe = "",
    [switch]$SkipTests
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

Write-Host "==> Shannon Windows install (pure-Python)" -ForegroundColor Cyan
$py = Get-PythonExe -Preferred $PythonExe
Write-Host "    Python: $py"

Invoke-Python -Exe $py -PyArgs @("-c", "import sys; assert sys.version_info >= (3, 10), sys.version; print(sys.version.split()[0])")

$env:SHANNON_SKIP_CORE = "1"
Write-Host "    SHANNON_SKIP_CORE=1 (pure-Python; no MSVC required)"

Invoke-Python -Exe $py -PyArgs @("-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel")

if ($Source -eq "pypi") {
    Write-Host "==> pip install shannon-entropy"
    Invoke-Python -Exe $py -PyArgs @("-m", "pip", "install", "shannon-entropy")
} elseif ($Source -eq "path") {
    if (-not (Test-Path (Join-Path $RepoRoot "pyproject.toml"))) {
        throw "Local path install requires the Shannon repo root (missing pyproject.toml under $RepoRoot)"
    }
    Write-Host "==> pip install -e $RepoRoot"
    Invoke-Python -Exe $py -PyArgs @("-m", "pip", "install", "-e", $RepoRoot)
} else {
    Write-Host "==> pip install $Source"
    Invoke-Python -Exe $py -PyArgs @("-m", "pip", "install", $Source)
}

if ($SkipTests) {
    Write-Host "Install complete (tests skipped)" -ForegroundColor Green
    exit 0
}

Write-Host "==> Smoke tests"
$smokeFile = Join-Path ([System.IO.Path]::GetTempPath()) ("shannon_smoke_{0}.py" -f [guid]::NewGuid().ToString("N"))
@'
import sys
import numpy as np
import shannon
from shannon import ShannonCollapseDetector, shannon_entropy_from_probs

assert shannon.__version__, shannon.__version__
print("shannon", shannon.__version__, "_HAS_CORE=", getattr(shannon, "_HAS_CORE", None))
h = shannon_entropy_from_probs(np.array([0.25, 0.25, 0.25, 0.25], dtype=float))
assert abs(h - 2.0) < 1e-9, h
ShannonCollapseDetector()
print("entropy_smoke_ok", h)
print("python", sys.version.split()[0])
'@ | Set-Content -Path $smokeFile -Encoding UTF8
try {
    Invoke-Python -Exe $py -PyArgs @($smokeFile)
} finally {
    Remove-Item -Force $smokeFile -ErrorAction SilentlyContinue
}

Write-Host "==> shannon-monitor --help"
try {
    Invoke-Python -Exe $py -PyArgs @("-m", "shannon.cli", "--help")
} catch {
    $mon = Get-Command shannon-monitor -ErrorAction SilentlyContinue
    if (-not $mon) { throw }
    & $mon.Source --help
    if ($LASTEXITCODE -ne 0) { throw "shannon-monitor --help failed" }
}

Write-Host "Shannon installed and smoke-tested on Windows PowerShell" -ForegroundColor Green
