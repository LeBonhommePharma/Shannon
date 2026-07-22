from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

import system_monitor as sm


class TestSchema:
    def test_open_db_creates_table(self, tmp_path):
        con = sm.open_db(tmp_path / "agent_hub.db")
        cur = con.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = {row[0] for row in cur.fetchall()}
        assert "system_metrics" in tables
        con.close()

    def test_inserted_row_matches_schema(self, tmp_path):
        con = sm.open_db(tmp_path / "agent_hub.db")
        con.execute("""
            INSERT INTO system_metrics
                (ts, cpu_percent, ram_used_gb, ram_total_gb,
                 ssd_used_gb, ssd_total_gb, thermal_state,
                 battery_pct, battery_watts, is_charging)
            VALUES (1.0, 12.5, 8.0, 16.0, 100.0, 500.0, 0, 80.0, 5.0, 1)
        """)
        con.commit()
        row = con.execute("SELECT * FROM system_metrics").fetchone()
        assert row is not None
        con.close()

    def test_trim_trigger_keeps_last_300(self, tmp_path):
        con = sm.open_db(tmp_path / "agent_hub.db")
        for i in range(305):
            con.execute("""
                INSERT INTO system_metrics (ts, cpu_percent) VALUES (?, ?)
            """, (float(i), 1.0))
        con.commit()
        count = con.execute("SELECT COUNT(*) FROM system_metrics").fetchone()[0]
        assert count == 300
        con.close()


class TestMetricPollingWithMockPsutil:
    def test_cpu_percent_uses_psutil_when_available(self):
        fake_psutil = SimpleNamespace(cpu_percent=MagicMock(return_value=42.0))
        with patch.object(sm, "HAS_PSUTIL", True), patch.object(sm, "_psutil", fake_psutil):
            assert sm.cpu_percent() == 42.0

    def test_ram_info_uses_psutil_when_available(self):
        fake_vm = SimpleNamespace(used=8_000_000_000, total=16_000_000_000)
        fake_psutil = SimpleNamespace(virtual_memory=MagicMock(return_value=fake_vm))
        with patch.object(sm, "HAS_PSUTIL", True), patch.object(sm, "_psutil", fake_psutil):
            used, total = sm.ram_info()
            assert used == pytest.approx(8.0)
            assert total == pytest.approx(16.0)

    def test_disk_info_uses_psutil_when_available(self):
        fake_disk = SimpleNamespace(used=100_000_000_000, total=500_000_000_000)
        fake_psutil = SimpleNamespace(disk_usage=MagicMock(return_value=fake_disk))
        with patch.object(sm, "HAS_PSUTIL", True), patch.object(sm, "_psutil", fake_psutil):
            used, total = sm.disk_info()
            assert used == pytest.approx(100.0)
            assert total == pytest.approx(500.0)

    def test_battery_info_uses_psutil_when_available(self):
        fake_battery = SimpleNamespace(percent=77.0, power_plugged=True)
        fake_psutil = SimpleNamespace(sensors_battery=MagicMock(return_value=fake_battery))
        with patch.object(sm, "HAS_PSUTIL", True), patch.object(sm, "_psutil", fake_psutil):
            pct, watts, charging = sm.battery_info()
            assert pct == pytest.approx(77.0)
            assert charging is True

    def test_battery_info_no_battery_returns_negative_one(self):
        fake_psutil = SimpleNamespace(sensors_battery=MagicMock(return_value=None))
        with patch.object(sm, "HAS_PSUTIL", True), patch.object(sm, "_psutil", fake_psutil):
            pct, watts, charging = sm.battery_info()
            assert pct == -1.0
            assert charging is False

    def test_cpu_percent_falls_back_without_psutil(self):
        with patch.object(sm, "HAS_PSUTIL", False), \
             patch("subprocess.check_output", side_effect=FileNotFoundError()):
            assert sm.cpu_percent() == 0.0
