"""Tests for hub/load_balance.py — pure ranking + multi-device preference."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import load_balance as lb


class TestRanking:
    def test_ram_beats_cpu(self):
        ranked = lb.constrained_ranked(cpu=40, ram=95)
        assert ranked[0]["kind"] == "ram"
        assert ranked[0]["percent"] == pytest.approx(95)

    def test_disk_full_first(self):
        ranked = lb.constrained_ranked(cpu=30, ram=40, disk=98, thermal=0)
        assert ranked[0]["kind"] == "disk"

    def test_thermal_critical_beats_disk_on_tie(self):
        ranked = lb.constrained_ranked(cpu=10, disk=97, thermal=3)
        assert ranked[0]["kind"] == "thermal"
        assert ranked[1]["kind"] == "disk"

    def test_disk_used_percent(self):
        assert lb.disk_used_percent(400, 500) == pytest.approx(80)
        assert lb.disk_used_percent(1, 0) is None


class TestLoadPreference:
    def test_preferred_picks_cool_peer(self):
        hot = {"id": "hot", "cpu_percent": 92, "ram_percent": 40}
        cool = {"id": "cool", "cpu_percent": 25, "ram_percent": 30}
        pick = lb.preferred_device([hot, cool])
        assert pick is not None
        assert pick["id"] == "cool"

    def test_should_defer_critical(self):
        assert lb.should_defer_work({"id": "x", "cpu_percent": 95}, threshold=90)
        assert not lb.should_defer_work({"id": "y", "cpu_percent": 50}, threshold=90)

    def test_should_run_locally_defers_when_peer_healthier(self):
        local = {"id": "local", "cpu_percent": 91}
        peer = {"id": "peer", "cpu_percent": 20}
        assert not lb.should_run_locally(local, [peer])
        assert lb.should_run_locally(peer, [local])

    def test_should_run_locally_when_alone(self):
        assert lb.should_run_locally({"id": "only", "cpu_percent": 50}, [])

    def test_capacity_from_system_metrics_row(self):
        row = {
            "cpu_percent": 55,
            "ram_used_gb": 8,
            "ram_total_gb": 16,
            "ssd_used_gb": 900,
            "ssd_total_gb": 1000,
            "thermal_state": 1,
        }
        cap = lb.capacity_from_system_metrics_row(row)
        assert cap["ram_percent"] == pytest.approx(50)
        assert cap["disk_percent"] == pytest.approx(90)
        assert cap["load_score"] == pytest.approx(90)  # disk wins
