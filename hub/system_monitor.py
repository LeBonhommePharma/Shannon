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

Usage
-----
  python system_monitor.py [--interval 2] [--db ~/.shannon/agent_hub.db]
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# ── Optional psutil ───────────────────────────────────────────────────────────

try:
    import psutil as _psutil   # type: ignore
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False

# ── Configuration ─────────────────────────────────────────────────────────────

DEFAULT_LOG_DIR = Path(os.environ.get("SHANNON_LOG_DIR",
    os.environ.get("FLEXAIDDS_LOG_DIR",         # backward compat
    str(Path.home() / ".shannon"))))
DEFAULT_DB      = DEFAULT_LOG_DIR / "agent_hub.db"
DEFAULT_INTERVAL = 2.0   # seconds


# ── SQLite ────────────────────────────────────────────────────────────────────

def open_db(path: Path) -> sqlite3.Connection:
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
    if HAS_PSUTIL:
        return _psutil.cpu_percent(interval=0.1)
    # Fallback: read /proc/stat (Linux) or top one-shot (macOS)
    try:
        out = subprocess.check_output(
            ["top", "-l", "2", "-n", "0", "-s", "0"],
            timeout=3, text=True
        )
        for line in out.splitlines():
            if "CPU usage" in line:
                parts = line.split(",")
                total = 0.0
                for p in parts:
                    p = p.strip()
                    if "user" in p or "sys" in p:
                        try:
                            total += float(p.split()[0].rstrip("%"))
                        except ValueError:
                            pass
                return min(total, 100.0)
    except Exception:
        pass
    return 0.0


def ram_info() -> tuple[float, float]:
    """Returns (used_gb, total_gb)."""
    if HAS_PSUTIL:
        v = _psutil.virtual_memory()
        return v.used / 1e9, v.total / 1e9
    try:
        out = subprocess.check_output(["vm_stat"], timeout=3, text=True)
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
        # total via sysctl
        raw = subprocess.check_output(["sysctl", "-n", "hw.memsize"], timeout=2, text=True)
        total = int(raw.strip()) / 1e9
        return used, total
    except Exception:
        return 0.0, 0.0


def disk_info() -> tuple[float, float]:
    """Returns (used_gb, total_gb) for root filesystem."""
    if HAS_PSUTIL:
        d = _psutil.disk_usage("/")
        return d.used / 1e9, d.total / 1e9
    try:
        out = subprocess.check_output(["df", "-k", "/"], timeout=2, text=True)
        lines = out.strip().splitlines()
        if len(lines) >= 2:
            parts = lines[-1].split()
            total = int(parts[1]) / 1e6   # kB → GB
            used  = int(parts[2]) / 1e6
            return used, total
    except Exception:
        pass
    return 0.0, 0.0


def thermal_state() -> int:
    """0=nominal 1=fair 2=serious 3=critical  (macOS only)."""
    try:
        out = subprocess.check_output(
            ["pmset", "-g", "therm"], timeout=2, text=True
        )
        if "CPU_Speed_Limit" in out:
            for line in out.splitlines():
                if "CPU_Speed_Limit" in line:
                    val = int(line.split()[-1])
                    if val <= 50:  return 3
                    if val <= 70:  return 2
                    if val <= 90:  return 1
    except Exception:
        pass
    return 0


def battery_info() -> tuple[float, float, bool]:
    """Returns (pct, watts, is_charging). pct=-1 if no battery."""
    if HAS_PSUTIL:
        try:
            b = _psutil.sensors_battery()
            if b is None:
                return -1.0, 0.0, False
            return b.percent, 0.0, b.power_plugged
        except Exception:
            pass
    try:
        out = subprocess.check_output(["pmset", "-g", "batt"], timeout=2, text=True)
        # Example: "Now drawing from 'Battery Power'\n-InternalBattery-0 (id=…)\t79%; discharging; …"
        pct = -1.0; charging = False; watts = 0.0
        for line in out.splitlines():
            if "%" in line:
                parts = line.split()
                for p in parts:
                    if p.endswith("%") or p.endswith("%;"):
                        try:
                            pct = float(p.rstrip("%;"))
                        except ValueError:
                            pass
                if "charging" in line.lower():
                    charging = True
        return pct, watts, charging
    except Exception:
        return -1.0, 0.0, False


# ── Main loop ─────────────────────────────────────────────────────────────────

def run(db_path: Path, interval: float) -> None:
    con = open_db(db_path)
    print(f"[system_monitor] polling every {interval}s → {db_path}", flush=True)
    while True:
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

        time.sleep(interval)


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
