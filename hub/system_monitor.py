#!/usr/bin/env python3
"""
system_monitor.py — Shannon Hub Resource Monitor
=================================================
Polls system resources and writes them to agent_hub.db for the Swift HUD.
Runs as a lightweight background process alongside the gate.

Metrics collected
-----------------
  cpu_percent        — overall CPU usage %
  ram_used_gb        — used RAM (GB)
  ram_total_gb       — physical RAM (GB)
  ssd_used_gb        — root filesystem used (GB)
  ssd_total_gb       — root filesystem total (GB)
  thermal_state      — 0=ok 1=fair 2=serious 3=critical  (macOS only)
  battery_pct        — battery % or -1 for AC desktop
  battery_watts      — power draw in watts
  is_charging        — 1 / 0

Uses psutil when available, falls back to subprocess (no-pip fallback).

Environment knobs
-----------------
  SHANNON_MONITOR_PSUTIL   "0"/"false"/"no"/"off" forces the subprocess
                           fallback even when psutil is installed. Default on.
                           Lets the no-psutil code path be exercised on a
                           machine that has psutil, and gives operators an
                           escape hatch if psutil misbehaves.

Usage
-----
  python system_monitor.py [--interval 2] [--db ~/.shannon/agent_hub.db]
"""

from __future__ import annotations

import argparse
import math
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

# ── Optional psutil ───────────────────────────────────────────────────────────
#
# `_psutil` is ALWAYS bound — to the module when the import succeeds, to None
# otherwise. Two reasons:
#
#   1. Call sites can guard on `_psutil is not None` instead of relying on the
#      `HAS_PSUTIL` flag alone. If the two ever disagree (flag forced True by a
#      caller, module absent) the collectors degrade to the subprocess fallback
#      instead of raising NameError inside the polling loop.
#   2. Tests can `patch.object(sm, "_psutil", fake)` on a machine without
#      psutil installed. `mock.patch` refuses to patch an attribute that does
#      not exist, so a conditionally-bound name makes the psutil branch
#      untestable exactly where it matters most — the clean machine.

_psutil: Any
try:
    import psutil as _psutil  # type: ignore[no-redef]
    HAS_PSUTIL = True
except ImportError:
    _psutil = None
    HAS_PSUTIL = False

# ── Configuration ─────────────────────────────────────────────────────────────

DEFAULT_LOG_DIR = Path(os.environ.get("SHANNON_LOG_DIR",
    os.environ.get("FLEXAIDDS_LOG_DIR",         # backward compat
    str(Path.home() / ".shannon"))))
DEFAULT_DB      = DEFAULT_LOG_DIR / "agent_hub.db"
DEFAULT_INTERVAL = 2.0   # seconds

# Upper bound on the text we will parse out of a helper process. `top`,
# `vm_stat`, `df` and `pmset` normally emit a few kB; anything wildly larger is
# a broken or hostile tool on PATH, and splitlines() on it would balloon the
# monitor's RSS. Truncate before parsing rather than trusting the producer.
MAX_TOOL_OUTPUT_CHARS = 1 << 20     # 1 MiB

# Sentinels written when a metric cannot be established. These are the values
# the Swift HUD already treats as "no reading", so refusing is representable.
UNKNOWN_GAUGE   = 0.0
UNKNOWN_BATTERY = -1.0

# Physical sanity bounds. A reading outside these is a parse error, not a
# measurement, and is refused rather than forwarded to the HUD.
MAX_CPU_PERCENT = 100.0
MAX_BYTES_GB    = 1e9        # 1 exabyte expressed in GB — no real host exceeds it

# Absolute paths to the macOS system tools used by the no-psutil fallback.
# $PATH is ambient state we do not control: on a developer box `top` commonly
# resolves to a shim (btop and friends) whose output this parser cannot read,
# and in the worst case it is an attacker-writable directory. Naming the real
# binaries takes PATH out of the trust surface. A path that does not exist on
# this OS simply makes `_run_tool` return None — i.e. "no reading".
TOOL_TOP     = "/usr/bin/top"
TOOL_VM_STAT = "/usr/bin/vm_stat"
TOOL_SYSCTL  = "/usr/sbin/sysctl"
TOOL_DF      = "/bin/df"
TOOL_PMSET   = "/usr/bin/pmset"


def _env_flag(name: str, default: bool) -> bool:
    """Read a SHANNON_* boolean knob. Unrecognised values keep the default."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    token = raw.strip().lower()
    if token in ("0", "false", "no", "off"):
        return False
    if token in ("1", "true", "yes", "on"):
        return True
    return default


def use_psutil() -> bool:
    """Whether the psutil code path should run right now.

    `HAS_PSUTIL` is a *capability* (did the import work). This is the *policy*:
    capability AND a live module object AND the operator has not switched it
    off. Every collector consults this, so all three conditions are checked on
    every poll rather than frozen at import time.
    """
    if _psutil is None or not HAS_PSUTIL:
        return False
    return _env_flag("SHANNON_MONITOR_PSUTIL", True)


def _gauge(value: Any, *, maximum: float, default: float = UNKNOWN_GAUGE) -> float:
    """Coerce a collected metric to a trustworthy float, else `default`.

    Fail closed: a value that is not a finite, non-negative number inside the
    documented range is a parse failure. Report the "no reading" sentinel
    rather than forwarding garbage that the HUD would render as a real
    measurement.
    """
    try:
        out = float(value)
    except (TypeError, ValueError):
        return default
    if not math.isfinite(out) or out < 0.0 or out > maximum:
        return default
    return out


def _run_tool(argv: list[str], timeout: float) -> str | None:
    """Run a system helper and return its (length-capped) stdout, or None.

    Returns None — never a partial guess — when the tool is missing, times out,
    exits non-zero, or is not on PATH. Callers treat None as "no reading".
    """
    try:
        out = subprocess.check_output(argv, timeout=timeout, text=True)
    except Exception:
        return None
    if not isinstance(out, str):
        return None
    if len(out) > MAX_TOOL_OUTPUT_CHARS:
        out = out[:MAX_TOOL_OUTPUT_CHARS]
    return out


# ── SQLite ────────────────────────────────────────────────────────────────────

def open_db(path: Path | str) -> sqlite3.Connection:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), check_same_thread=False)
    con.execute("PRAGMA journal_mode=WAL;")
    con.execute("""
        CREATE TABLE IF NOT EXISTS system_metrics (
            id           INTEGER PRIMARY KEY,
            ts           REAL    NOT NULL,
            cpu_percent  REAL    DEFAULT 0,
            ram_used_gb  REAL    DEFAULT 0,
            ram_total_gb REAL    DEFAULT 0,
            ssd_used_gb  REAL    DEFAULT 0,
            ssd_total_gb REAL    DEFAULT 0,
            thermal_state INTEGER DEFAULT 0,
            battery_pct  REAL    DEFAULT -1,
            battery_watts REAL   DEFAULT 0,
            is_charging  INTEGER DEFAULT 0
        );
    """)
    # Keep only last 300 rows (10 min at 2s)
    con.execute("""
        CREATE TRIGGER IF NOT EXISTS trim_metrics AFTER INSERT ON system_metrics
        BEGIN
            DELETE FROM system_metrics
            WHERE id NOT IN (SELECT id FROM system_metrics ORDER BY id DESC LIMIT 300);
        END;
    """)
    con.commit()
    return con


# ── Resource collectors ───────────────────────────────────────────────────────

def cpu_percent() -> float:
    if use_psutil():
        try:
            return _gauge(_psutil.cpu_percent(interval=0.1), maximum=MAX_CPU_PERCENT)
        except Exception:
            return UNKNOWN_GAUGE
    # Fallback: `top` one-shot (macOS).
    out = _run_tool([TOOL_TOP, "-l", "2", "-n", "0", "-s", "0"], timeout=3)
    if out is None:
        return UNKNOWN_GAUGE
    try:
        for line in out.splitlines():
            if "CPU usage" in line:
                # Line shape: "CPU usage: 86.38% user, 13.61% sys, 0.0% idle"
                #
                # Splitting on "," and reading token[0] of each segment loses
                # the user share: segment 0 is "CPU usage: 86.38% user", whose
                # first token is "CPU", so float() raised and the busiest
                # component was silently dropped. A pegged machine reported
                # 13.61%. Take the percentage token from each segment instead
                # of assuming its position.
                total = 0.0
                for segment in line.split(","):
                    segment = segment.strip()
                    if not (segment.endswith("user") or segment.endswith("sys")):
                        continue
                    for token in segment.split():
                        if token.endswith("%"):
                            try:
                                total += float(token.rstrip("%"))
                            except ValueError:
                                pass
                            break
                # Clamp rather than trust: a malformed `top` line can sum to a
                # negative or absurd total, which must not reach the HUD.
                return _gauge(min(total, MAX_CPU_PERCENT), maximum=MAX_CPU_PERCENT)
    except Exception:
        pass
    return UNKNOWN_GAUGE


def _consistent_pair(used: Any, total: Any) -> tuple[float, float]:
    """Validate a (used, total) gauge pair, refusing anything incoherent.

    `used > total` is arithmetically impossible for memory or disk, so it
    signals a bad parse. Report (0, 0) — "no reading" — instead of a
    utilisation figure the HUD would draw as >100 %.
    """
    used_gb = _gauge(used, maximum=MAX_BYTES_GB)
    total_gb = _gauge(total, maximum=MAX_BYTES_GB)
    if total_gb <= 0.0 or used_gb > total_gb:
        return UNKNOWN_GAUGE, UNKNOWN_GAUGE
    return used_gb, total_gb


def ram_info() -> tuple[float, float]:
    """Returns (used_gb, total_gb). (0, 0) means no trustworthy reading."""
    if use_psutil():
        try:
            v = _psutil.virtual_memory()
            return _consistent_pair(v.used / 1e9, v.total / 1e9)
        except Exception:
            return UNKNOWN_GAUGE, UNKNOWN_GAUGE
    out = _run_tool([TOOL_VM_STAT], timeout=3)
    raw = _run_tool([TOOL_SYSCTL, "-n", "hw.memsize"], timeout=2)
    if out is None or raw is None:
        return UNKNOWN_GAUGE, UNKNOWN_GAUGE
    try:
        pages: dict[str, int] = {}
        for line in out.splitlines():
            if ":" in line:
                k, _, v = line.partition(":")
                try:
                    pages[k.strip()] = int(v.strip().rstrip("."))
                except ValueError:
                    pass
        page = 4096
        used = (pages.get("Pages active", 0) +
                pages.get("Pages wired down", 0) +
                pages.get("Pages occupied by compressor", 0)) * page / 1e9
        total = int(raw.strip()) / 1e9
    except Exception:
        return UNKNOWN_GAUGE, UNKNOWN_GAUGE
    return _consistent_pair(used, total)


def disk_info() -> tuple[float, float]:
    """Returns (used_gb, total_gb) for root filesystem, (0, 0) if unknown."""
    if use_psutil():
        try:
            d = _psutil.disk_usage("/")
            return _consistent_pair(d.used / 1e9, d.total / 1e9)
        except Exception:
            return UNKNOWN_GAUGE, UNKNOWN_GAUGE
    out = _run_tool([TOOL_DF, "-k", "/"], timeout=2)
    if out is None:
        return UNKNOWN_GAUGE, UNKNOWN_GAUGE
    try:
        lines = out.strip().splitlines()
        if len(lines) >= 2:
            parts = lines[-1].split()
            total = int(parts[1]) / 1e6   # kB → GB
            used  = int(parts[2]) / 1e6
            return _consistent_pair(used, total)
    except (ValueError, IndexError):
        pass
    except Exception:
        pass
    return UNKNOWN_GAUGE, UNKNOWN_GAUGE


def thermal_state() -> int:
    """0=nominal 1=fair 2=serious 3=critical  (macOS only)."""
    out = _run_tool([TOOL_PMSET, "-g", "therm"], timeout=2)
    if out is None:
        return 0
    try:
        if "CPU_Speed_Limit" in out:
            for line in out.splitlines():
                if "CPU_Speed_Limit" in line:
                    val = int(line.split()[-1])
                    if val <= 50:  return 3
                    if val <= 70:  return 2
                    if val <= 90:  return 1
    except (ValueError, IndexError):
        pass
    except Exception:
        pass
    return 0


def battery_info() -> tuple[float, float, bool]:
    """Returns (pct, watts, is_charging). pct=-1 if no battery / no reading."""
    if use_psutil():
        try:
            b = _psutil.sensors_battery()
            if b is None:
                return UNKNOWN_BATTERY, 0.0, False
            pct = _gauge(b.percent, maximum=MAX_CPU_PERCENT, default=UNKNOWN_BATTERY)
            return pct, 0.0, bool(b.power_plugged)
        except Exception:
            return UNKNOWN_BATTERY, 0.0, False
    out = _run_tool([TOOL_PMSET, "-g", "batt"], timeout=2)
    if out is None:
        return UNKNOWN_BATTERY, 0.0, False
    # Example: "Now drawing from 'Battery Power'\n-InternalBattery-0 (id=…)\t79%; discharging; …"
    pct = UNKNOWN_BATTERY; charging = False; watts = 0.0
    try:
        for line in out.splitlines():
            low = line.lower()
            if "%" in line:
                for p in line.split():
                    if p.endswith("%") or p.endswith("%;"):
                        pct = _gauge(p.rstrip("%;"), maximum=MAX_CPU_PERCENT,
                                     default=UNKNOWN_BATTERY)
            # `is_charging` mirrors psutil's `power_plugged`: is the machine on
            # wall power. pmset's header line is the authority.
            #
            # Substring matching on "charging" is a trap — "discharging" and
            # "not charging" both contain it, so the naive test reported a
            # draining battery as charging. Match on explicit tokens only.
            if "drawing from 'ac power'" in low:
                charging = True
            elif "drawing from 'battery power'" in low:
                charging = False
            elif "; charging;" in low or "; charged;" in low:
                charging = True
    except Exception:
        return UNKNOWN_BATTERY, 0.0, False
    return pct, watts, charging


# ── Main loop ─────────────────────────────────────────────────────────────────

def run(db_path: Path, interval: float, max_polls: int | None = None) -> None:
    """Poll forever, or exactly `max_polls` times when given.

    `max_polls` exists so the insert path can be exercised by a test without a
    thread, a signal, or a wall-clock race; production leaves it at None.
    """
    con = open_db(db_path)
    print(f"[system_monitor] polling every {interval}s → {db_path}", flush=True)
    polls = 0
    while max_polls is None or polls < max_polls:
        polls += 1
        try:
            cpu   = cpu_percent()
            ram_u, ram_t = ram_info()
            ssd_u, ssd_t = disk_info()
            therm = thermal_state()
            bat_p, bat_w, charging = battery_info()

            con.execute("""
                INSERT INTO system_metrics
                    (ts, cpu_percent, ram_used_gb, ram_total_gb,
                     ssd_used_gb, ssd_total_gb,
                     thermal_state, battery_pct, battery_watts, is_charging)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, (time.time(), cpu, ram_u, ram_t,
                  ssd_u, ssd_t, therm, bat_p, bat_w, int(charging)))
            con.commit()

        except Exception as exc:
            print(f"[system_monitor] poll error: {exc}", file=sys.stderr)

        if max_polls is not None and polls >= max_polls:
            break
        time.sleep(interval)
    con.close()


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Shannon system resource monitor")
    ap.add_argument("--db",       default=str(DEFAULT_DB), help="Path to agent_hub.db")
    ap.add_argument("--interval", default=DEFAULT_INTERVAL, type=float,
                    help="Poll interval in seconds (default 2)")
    args = ap.parse_args()
    try:
        run(Path(args.db), args.interval)
    except KeyboardInterrupt:
        print("\n[system_monitor] stopped.")
