#!/usr/bin/env python3
"""Assert product version is consistent across packaging sources.

Exit 0 when VERSION, pyproject.toml [project].version, python/shannon
__version__, and CMake project VERSION all match. Optional --expect X.Y.Z.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_version_file() -> str:
    return (ROOT / "VERSION").read_text(encoding="utf-8").strip()


def read_pyproject() -> str:
    text = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    in_project = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            in_project = s == "[project]"
            continue
        if in_project and s.startswith("version") and "=" in s:
            return s.split("=", 1)[1].strip().strip("\"'")
    raise SystemExit("pyproject.toml [project].version not found")


def read_init() -> str:
    text = (ROOT / "python" / "shannon" / "__init__.py").read_text(encoding="utf-8")
    m = re.search(r'^__version__\s*=\s*["\']([^"\']+)["\']', text, re.M)
    if not m:
        raise SystemExit("python/shannon/__init__.py __version__ not found")
    return m.group(1)


def read_cmake() -> str:
    text = (ROOT / "CMakeLists.txt").read_text(encoding="utf-8")
    m = re.search(r"project\s*\(\s*shannon\s+VERSION\s+([0-9][^)\s]*)", text, re.I)
    if not m:
        raise SystemExit("CMakeLists.txt project VERSION not found")
    return m.group(1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--expect", default=None, help="Expected version (e.g. 2.1.0)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    versions = {
        "VERSION": read_version_file(),
        "pyproject": read_pyproject(),
        "init": read_init(),
        "cmake": read_cmake(),
    }
    unique = set(versions.values())
    ok = len(unique) == 1
    expected = args.expect
    if expected is not None:
        ok = ok and unique == {expected}

    if args.json:
        import json

        print(json.dumps({"ok": ok, "versions": versions, "expect": expected}, indent=2))
    else:
        for k, v in versions.items():
            print(f"{k:12} {v}")
        if expected:
            print(f"{'expect':12} {expected}")
        print("aligned" if ok else "MISMATCH")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
