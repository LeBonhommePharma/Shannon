#!/usr/bin/env python3
"""Shannon pure-Python package installer / updater (cross-platform).

Install or update ``shannon-entropy`` from PyPI, a local monorepo clone, or a
Git URL. Always sets ``SHANNON_SKIP_CORE=1`` so missing C++ toolchains never
fail the install. Re-running the same command is the supported **update** path
after ``git pull`` (or a newer checkout).

Entry points
------------
Unix/macOS::

    ./scripts/install_shannon.sh --path
    python3 scripts/shannon_installer.py --source path
    python3 scripts/shannon_installer.py --source path --update   # same as install

Windows (PowerShell wrapper)::

    .\\scripts\\Install-Shannon.ps1 -Source path
    python scripts/shannon_installer.py --source path

GitHub without a prior clone::

    python3 scripts/shannon_installer.py --source git
    # or: --source 'git+https://github.com/LeBonhommePharma/Shannon.git'
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path
from typing import Sequence

# Windows hosted runners default to cp1252/charmap; force UTF-8 stdio so
# installer logs never raise UnicodeEncodeError on non-ASCII status glyphs.
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001 — best-effort; fall back to ASCII markers
        pass

# Default public monorepo (science package + docs live here).
DEFAULT_GIT_URL = "git+https://github.com/LeBonhommePharma/Shannon.git"
DEFAULT_PYPI_NAME = "shannon-entropy"

# Fixed smoke: uniform 4-class distribution → H = 2 bits exactly.
_SMOKE_PROBS = (0.25, 0.25, 0.25, 0.25)
_SMOKE_EXPECTED_H = 2.0
_SMOKE_TOL = 1e-9

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_VENV_DIRNAME = ".venv-shannon"

# ASCII-safe log markers (Windows cp1252 cannot encode → / ✓ / ✗).
_ARROW = "->"
_OK = "[ok]"
_FAIL = "[fail]"


def resolve_source(
    source: str,
    *,
    repo_root: Path | None = None,
) -> list[str]:
    """Map a user source token to ``pip install`` arguments (after the verb).

    Modes
    -----
    * ``pypi`` / ``release`` → install published ``shannon-entropy``
    * ``path`` / ``local`` / ``editable`` / ``source`` → ``-e <repo_root>``
    * ``git`` / ``github`` / ``head`` → default GitHub ``git+https://…``
    * ``git+…`` / ``https://…`` / ``http://…`` → passed through to pip
    * existing directory with ``pyproject.toml`` → editable install of that path
    * anything else → single pip requirement token (e.g. ``shannon-entropy==2.1.0``)
    """
    root = (repo_root or REPO_ROOT).resolve()
    raw = (source or "").strip()
    if not raw:
        raise ValueError("source must be non-empty")

    key = raw.lower()
    if key in ("pypi", "py", "release"):
        return [DEFAULT_PYPI_NAME]
    if key in ("path", "local", "editable", "source", "clone"):
        if not (root / "pyproject.toml").is_file():
            raise FileNotFoundError(
                f"path install requires pyproject.toml under {root}"
            )
        return ["-e", str(root)]
    if key in ("git", "github", "head"):
        return [DEFAULT_GIT_URL]
    if key.startswith("git+") or key.startswith("https://") or key.startswith("http://"):
        return [raw]

    candidate = Path(raw).expanduser()
    if candidate.is_dir() and (candidate / "pyproject.toml").is_file():
        return ["-e", str(candidate.resolve())]

    return [raw]


def source_kind(source: str) -> str:
    """Coarse kind for diagnostics: pypi | path | git | requirement."""
    args = resolve_source(source)
    if args == [DEFAULT_PYPI_NAME]:
        return "pypi"
    if len(args) == 2 and args[0] == "-e":
        return "path"
    if args and (args[0].startswith("git+") or "github.com" in args[0].lower()):
        return "git"
    return "requirement"


def run_entropy_smoke(*, python: str | None = None) -> dict[str, object]:
    """Import installed shannon and assert fixed-distribution entropy smoke.

    Returns a result dict with version, entropy, and has_core flags.
    Raises AssertionError / ImportError on failure.
    """
    code = r"""
import json
import sys
import numpy as np
import shannon
from shannon import ShannonCollapseDetector, shannon_entropy_from_probs

assert shannon.__version__, repr(shannon.__version__)
probs = np.array([0.25, 0.25, 0.25, 0.25], dtype=float)
h = float(shannon_entropy_from_probs(probs))
assert abs(h - 2.0) < 1e-9, h
ShannonCollapseDetector()
out = {
    "version": shannon.__version__,
    "entropy": h,
    "has_core": bool(getattr(shannon, "_HAS_CORE", False)),
    "python": sys.version.split()[0],
    "entropy_smoke_ok": True,
}
print(json.dumps(out))
"""
    exe = python or sys.executable
    proc = subprocess.run(
        [exe, "-c", code],
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "SHANNON_SKIP_CORE": os.environ.get("SHANNON_SKIP_CORE", "1")},
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"entropy smoke failed (exit {proc.returncode}):\n"
            f"{proc.stdout}\n{proc.stderr}"
        )
    # Last non-empty line should be JSON.
    lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
    if not lines:
        raise RuntimeError(f"entropy smoke produced no stdout:\n{proc.stderr}")
    import json

    result = json.loads(lines[-1])
    if not result.get("entropy_smoke_ok"):
        raise RuntimeError(f"smoke dict missing ok flag: {result}")
    if not result.get("version"):
        raise RuntimeError(f"empty version in smoke: {result}")
    return result


def run_monitor_help(*, python: str | None = None) -> None:
    """Ensure shannon-monitor / ``python -m shannon.cli --help`` works."""
    exe = python or sys.executable
    proc = subprocess.run(
        [exe, "-m", "shannon.cli", "--help"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        # Fallback: console script if present on PATH.
        which = subprocess.run(
            ["shannon-monitor", "--help"],
            capture_output=True,
            text=True,
            check=False,
        )
        if which.returncode != 0:
            raise RuntimeError(
                "shannon.cli --help and shannon-monitor --help both failed:\n"
                f"{proc.stderr}\n{which.stderr}"
            )


def is_externally_managed(python: str) -> bool:
    """True when this interpreter refuses system-wide pip installs (PEP 668)."""
    code = (
        "import sys, sysconfig, pathlib\n"
        "p = pathlib.Path(sysconfig.get_path('stdlib')) / 'EXTERNALLY-MANAGED'\n"
        "print('1' if p.is_file() else '0')\n"
    )
    proc = subprocess.run(
        [python, "-c", code],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode == 0 and proc.stdout.strip().startswith("1"):
        return True
    # Fallback probe: pip may still report the error without the marker file.
    probe = subprocess.run(
        [python, "-m", "pip", "install", "--dry-run", "pip"],
        capture_output=True,
        text=True,
        check=False,
    )
    blob = (probe.stdout or "") + (probe.stderr or "")
    return "externally-managed-environment" in blob


def venv_python(venv_dir: Path) -> Path:
    """Return the venv interpreter path (POSIX or Windows)."""
    if sys.platform == "win32":
        return venv_dir / "Scripts" / "python.exe"
    return venv_dir / "bin" / "python"


def ensure_venv(base_python: str, venv_dir: Path) -> str:
    """Create *venv_dir* if needed; return path to its python executable."""
    py = venv_python(venv_dir)
    if py.is_file():
        print(f"{_ARROW} reusing venv {venv_dir}", flush=True)
        return str(py)
    print(f"{_ARROW} creating venv at {venv_dir}", flush=True)
    subprocess.run([base_python, "-m", "venv", str(venv_dir)], check=True)
    if not py.is_file():
        raise RuntimeError(f"venv created but interpreter missing: {py}")
    return str(py)


def _pip_install(pip_args: Sequence[str], *, python: str) -> None:
    cmd = [python, "-m", "pip", "install", *pip_args]
    print(f"{_ARROW} {' '.join(cmd)}", flush=True)
    subprocess.run(cmd, check=True)


def _upgrade_pip(python: str) -> None:
    subprocess.run(
        [python, "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"],
        check=True,
    )


def install(
    source: str = "path",
    *,
    repo_root: Path | None = None,
    python: str | None = None,
    skip_tests: bool = False,
    upgrade_pip: bool = True,
    update: bool = False,
    use_venv: bool | None = None,
    venv_dir: Path | None = None,
) -> dict[str, object]:
    """Install (or re-install / update) shannon-entropy from *source*.

    ``update=True`` is documentation-only — behaviour is identical to install
    (idempotent re-run after git pull). Returns smoke result dict, or a
    minimal status when tests are skipped.

    When the base interpreter is PEP 668 externally-managed (Homebrew / Debian
    system Python), a project venv is created automatically unless
    ``use_venv=False``.
    """
    root = (repo_root or REPO_ROOT).resolve()
    base_exe = python or sys.executable
    os.environ["SHANNON_SKIP_CORE"] = "1"

    # Prove Python floor on the *base* interpreter.
    ver_proc = subprocess.run(
        [base_exe, "-c", "import sys; assert sys.version_info >= (3, 10); print(sys.version.split()[0])"],
        capture_output=True,
        text=True,
        check=False,
    )
    if ver_proc.returncode != 0:
        raise RuntimeError(f"Python 3.10+ required: {ver_proc.stderr or ver_proc.stdout}")

    # Auto-venv for PEP 668 so `./scripts/install_shannon.sh --path` just works.
    exe = base_exe
    venv_used: Path | None = None
    auto = use_venv
    if auto is None:
        auto = is_externally_managed(base_exe)
    if auto:
        vdir = (venv_dir or (root / DEFAULT_VENV_DIRNAME)).resolve()
        exe = ensure_venv(base_exe, vdir)
        venv_used = vdir
        # Re-check version inside venv (should match base).
        ver_proc = subprocess.run(
            [exe, "-c", "import sys; print(sys.version.split()[0])"],
            capture_output=True,
            text=True,
            check=True,
        )

    pip_args = resolve_source(source, repo_root=root)
    kind = source_kind(source)
    action = "update" if update else "install"
    print(f"==> Shannon pure-Python {action} (source={kind})", flush=True)
    print(f"    Python: {exe} ({ver_proc.stdout.strip()})", flush=True)
    if venv_used is not None:
        print(f"    venv: {venv_used}", flush=True)
    print("    SHANNON_SKIP_CORE=1", flush=True)
    print(f"    pip args: {pip_args}", flush=True)

    if upgrade_pip:
        print(f"{_ARROW} upgrading pip/setuptools/wheel", flush=True)
        _upgrade_pip(exe)

    _pip_install(pip_args, python=exe)

    if skip_tests:
        print(f"{_OK} Install complete (tests skipped)", flush=True)
        return {
            "skipped_tests": True,
            "source": kind,
            "pip_args": list(pip_args),
            "python": exe,
            "venv": str(venv_used) if venv_used else None,
        }

    print(f"{_ARROW} smoke: import + entropy", flush=True)
    smoke = run_entropy_smoke(python=exe)
    print(
        f"{_OK} entropy_smoke_ok version={smoke['version']} H={smoke['entropy']} "
        f"_HAS_CORE={smoke['has_core']}",
        flush=True,
    )

    print(f"{_ARROW} smoke: shannon-monitor / shannon.cli --help", flush=True)
    run_monitor_help(python=exe)
    print(f"{_OK} monitor_help_ok", flush=True)
    print(f"{_OK} Shannon pure-Python {action} smoke passed", flush=True)
    if venv_used is not None:
        activate = (
            f"{venv_used}\\Scripts\\Activate.ps1"
            if sys.platform == "win32"
            else f"source {venv_used}/bin/activate"
        )
        print(f"  To use this install: {activate}", flush=True)
    smoke = dict(smoke)
    smoke["source"] = kind
    smoke["pip_args"] = list(pip_args)
    smoke["action"] = action
    smoke["python"] = exe
    smoke["venv"] = str(venv_used) if venv_used else None
    return smoke


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="shannon_installer",
        description=(
            "Install or update shannon-entropy from PyPI, local clone path, or git URL. "
            "Re-run after git pull to update."
        ),
    )
    p.add_argument(
        "--source",
        default="path",
        help=(
            "pypi | path | git | git+URL | local dir | pip requirement "
            "(default: path = editable install of this monorepo)"
        ),
    )
    p.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="Monorepo root for --source path (default: parent of scripts/)",
    )
    p.add_argument(
        "--python",
        default=None,
        help="Python executable (default: current interpreter)",
    )
    p.add_argument(
        "--skip-tests",
        action="store_true",
        help="Install only; skip entropy / CLI smoke",
    )
    p.add_argument(
        "--no-upgrade-pip",
        action="store_true",
        help="Do not upgrade pip/setuptools/wheel first",
    )
    p.add_argument(
        "--venv",
        action="store_true",
        help=f"Force a project venv at <repo>/{DEFAULT_VENV_DIRNAME}",
    )
    p.add_argument(
        "--no-venv",
        action="store_true",
        help="Never auto-create a venv (fail on PEP 668 system Python)",
    )
    p.add_argument(
        "--venv-dir",
        type=Path,
        default=None,
        help=f"Custom venv directory (implies --venv; default <repo>/{DEFAULT_VENV_DIRNAME})",
    )
    p.add_argument(
        "--update",
        action="store_true",
        help="Alias for re-install from the same source (idempotent update)",
    )
    p.add_argument(
        "--resolve-only",
        action="store_true",
        help="Print resolved pip args as JSON and exit (no install)",
    )
    p.add_argument(
        "--smoke-only",
        action="store_true",
        help="Run entropy + monitor smoke against currently installed package",
    )
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(list(argv) if argv is not None else None)

    if args.resolve_only:
        import json

        pip_args = resolve_source(args.source, repo_root=args.repo_root)
        print(
            json.dumps(
                {
                    "source": args.source,
                    "kind": source_kind(args.source),
                    "pip_args": pip_args,
                }
            )
        )
        return 0

    if args.smoke_only:
        smoke = run_entropy_smoke(python=args.python)
        run_monitor_help(python=args.python)
        print(
            f"entropy_smoke_ok version={smoke['version']} H={smoke['entropy']}",
            flush=True,
        )
        return 0

    use_venv: bool | None
    if args.no_venv:
        use_venv = False
    elif args.venv or args.venv_dir is not None:
        use_venv = True
    else:
        use_venv = None  # auto on PEP 668

    try:
        install(
            args.source,
            repo_root=args.repo_root,
            python=args.python,
            skip_tests=args.skip_tests,
            upgrade_pip=not args.no_upgrade_pip,
            update=args.update,
            use_venv=use_venv,
            venv_dir=args.venv_dir,
        )
    except Exception as exc:  # noqa: BLE001 — CLI boundary
        print(f"{_FAIL} {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
