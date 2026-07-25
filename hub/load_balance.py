"""
load_balance.py — pure multi-device load preference for concurrent benchmarking.

Mirrors ShannonCore LoadBalancePolicy so hub tooling can prefer healthier hosts
without Swift. No I/O — unit-tested with synthetic capacity dicts.
"""

from __future__ import annotations

from typing import Any, Optional

# Thermal ladder pressure % (aligned with HostThermalState.pressurePercent).
THERMAL_PRESSURE: dict[int, float] = {
    0: 8.0,   # nominal
    1: 45.0,  # fair
    2: 78.0,  # serious
    3: 97.0,  # critical
}

# Tie-break severity when utilisation is equal (higher = more severe).
KIND_SEVERITY: dict[str, int] = {
    "thermal": 5,
    "disk": 4,
    "ram": 3,
    "gpu": 2,
    "cpu": 1,
}


def clamp_pct(v: Any) -> Optional[float]:
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    if x != x:  # NaN
        return None
    return max(0.0, min(100.0, x))


def disk_used_percent(used: float, total: float) -> Optional[float]:
    if total <= 0 or used < 0:
        return None
    return clamp_pct((used / total) * 100.0)


def thermal_pressure(state: Any) -> Optional[float]:
    try:
        s = int(state)
    except (TypeError, ValueError):
        return None
    return THERMAL_PRESSURE.get(s)


def constrained_ranked(
    cpu: Any = None,
    gpu: Any = None,
    ram: Any = None,
    disk: Any = None,
    thermal: Any = None,
) -> list[dict[str, Any]]:
    """Return gauges sorted most constrained first."""
    mapping = {
        "cpu": clamp_pct(cpu),
        "gpu": clamp_pct(gpu),
        "ram": clamp_pct(ram),
        "disk": clamp_pct(disk),
        "thermal": thermal_pressure(thermal) if thermal is not None else None,
    }
    rows = [(k, p) for k, p in mapping.items() if p is not None]
    rows.sort(key=lambda kv: (-kv[1], -KIND_SEVERITY.get(kv[0], 0)))
    return [{"kind": k, "percent": p} for k, p in rows]


def load_score(
    cpu: Any = None,
    gpu: Any = None,
    ram: Any = None,
    disk: Any = None,
    thermal: Any = None,
    *,
    ssd_used_gb: Any = None,
    ssd_total_gb: Any = None,
) -> float:
    """0…100 pressure score (max gauge). Higher = more constrained."""
    disk_pct = clamp_pct(disk)
    if disk_pct is None and ssd_used_gb is not None and ssd_total_gb is not None:
        try:
            disk_pct = disk_used_percent(float(ssd_used_gb), float(ssd_total_gb))
        except (TypeError, ValueError):
            disk_pct = None
    ranked = constrained_ranked(
        cpu=cpu, gpu=gpu, ram=ram, disk=disk_pct, thermal=thermal
    )
    return float(ranked[0]["percent"]) if ranked else 0.0


def preferred_device(
    devices: list[dict[str, Any]],
    *,
    busy_threshold: float = 85.0,
) -> Optional[dict[str, Any]]:
    """
    Pick the least constrained device.

    Each device dict needs at least:
      id, and either load_score or metric fields (cpu_percent, …).
    """
    if not devices:
        return None
    scored: list[tuple[float, str, dict[str, Any]]] = []
    for d in devices:
        if "load_score" in d:
            score = float(d["load_score"])
        else:
            score = load_score(
                cpu=d.get("cpu_percent"),
                gpu=d.get("gpu_percent"),
                ram=d.get("ram_percent"),
                disk=d.get("disk_percent"),
                thermal=d.get("thermal_state"),
                ssd_used_gb=d.get("ssd_used_gb"),
                ssd_total_gb=d.get("ssd_total_gb"),
            )
        did = str(d.get("id") or d.get("device_id") or d.get("name") or "")
        scored.append((score, did, d))
    scored.sort(key=lambda t: (t[0], t[1]))
    for score, _, d in scored:
        if score < busy_threshold:
            return d
    return scored[0][2]


def should_defer_work(device: dict[str, Any], *, threshold: float = 90.0) -> bool:
    if "load_score" in device:
        score = float(device["load_score"])
    else:
        score = load_score(
            cpu=device.get("cpu_percent"),
            gpu=device.get("gpu_percent"),
            ram=device.get("ram_percent"),
            disk=device.get("disk_percent"),
            thermal=device.get("thermal_state"),
            ssd_used_gb=device.get("ssd_used_gb"),
            ssd_total_gb=device.get("ssd_total_gb"),
        )
    return score >= threshold


def should_run_locally(
    local: dict[str, Any],
    peers: list[dict[str, Any]],
    *,
    busy_threshold: float = 85.0,
    defer_threshold: float = 90.0,
) -> bool:
    if should_defer_work(local, threshold=defer_threshold):
        best = preferred_device([local] + list(peers), busy_threshold=busy_threshold)
        if best is None:
            return False
        lid = str(local.get("id") or local.get("device_id") or "")
        bid = str(best.get("id") or best.get("device_id") or "")
        return lid == bid
    if not peers:
        return True
    best = preferred_device([local] + list(peers), busy_threshold=busy_threshold)
    if best is None:
        return True
    lid = str(local.get("id") or local.get("device_id") or "")
    bid = str(best.get("id") or best.get("device_id") or "")
    return lid == bid


def capacity_from_system_metrics_row(row: dict[str, Any]) -> dict[str, Any]:
    """Map a system_metrics DB row (or system_monitor poll) to capacity fields."""
    ram_u = row.get("ram_used_gb")
    ram_t = row.get("ram_total_gb")
    ram_pct = None
    if ram_u is not None and ram_t is not None:
        try:
            ram_pct = disk_used_percent(float(ram_u), float(ram_t))  # same math
        except (TypeError, ValueError):
            ram_pct = None
    ssd_u = row.get("ssd_used_gb")
    ssd_t = row.get("ssd_total_gb")
    disk_pct = None
    if ssd_u is not None and ssd_t is not None:
        try:
            disk_pct = disk_used_percent(float(ssd_u), float(ssd_t))
        except (TypeError, ValueError):
            disk_pct = None
    return {
        "cpu_percent": row.get("cpu_percent"),
        "ram_percent": ram_pct,
        "disk_percent": disk_pct,
        "ssd_used_gb": ssd_u,
        "ssd_total_gb": ssd_t,
        "thermal_state": row.get("thermal_state"),
        "load_score": load_score(
            cpu=row.get("cpu_percent"),
            ram=ram_pct,
            disk=disk_pct,
            thermal=row.get("thermal_state"),
        ),
    }
