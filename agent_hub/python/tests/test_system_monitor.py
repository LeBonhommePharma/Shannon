"""Tests for system_monitor.py — DB uses tmp_path; psutil/subprocess mocked where relevant."""
from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import system_monitor  # noqa: E402


class TestOpenDb:
    def test_creates_table(self, tmp_path):
        con = system_monitor.open_db(tmp_path / "hub.db")
        cur = con.execute("SELECT name FROM sqlite_master WHERE type='table'")
        names = {row[0] for row in cur.fetchall()}
        assert "system_metrics" in names
        con.close()


class TestCpuPercent:
    @patch("system_monitor.HAS_PSUTIL", True)
    @patch("system_monitor._psutil")
    def test_uses_psutil_when_available(self, mock_psutil):
        mock_psutil.cpu_percent.return_value = 42.0
        assert system_monitor.cpu_percent() == 42.0

    @patch("system_monitor.HAS_PSUTIL", False)
    @patch("system_monitor.subprocess.check_output")
    def test_falls_back_without_psutil(self, mock_check_output):
        mock_check_output.side_effect = Exception("no top on this box")
        assert system_monitor.cpu_percent() == 0.0


class TestRamInfo:
    @patch("system_monitor.HAS_PSUTIL", True)
    @patch("system_monitor._psutil")
    def test_ram_info_psutil(self, mock_psutil):
        mem = MagicMock(used=8e9, total=16e9)
        mock_psutil.virtual_memory.return_value = mem
        used, total = system_monitor.ram_info()
        assert used == 8.0
        assert total == 16.0


class TestDiskInfo:
    @patch("system_monitor.HAS_PSUTIL", True)
    @patch("system_monitor._psutil")
    def test_disk_info_psutil(self, mock_psutil):
        d = MagicMock(used=100e9, total=500e9)
        mock_psutil.disk_usage.return_value = d
        used, total = system_monitor.disk_info()
        assert used == 100.0
        assert total == 500.0


class TestThermalState:
    @patch("system_monitor.subprocess.check_output")
    def test_nominal_when_no_limit_reported(self, mock_check_output):
        mock_check_output.return_value = "No limit"
        assert system_monitor.thermal_state() == 0

    @patch("system_monitor.subprocess.check_output")
    def test_critical_when_speed_limit_low(self, mock_check_output):
        mock_check_output.return_value = "CPU_Speed_Limit = 40"
        assert system_monitor.thermal_state() == 3


class TestBatteryInfo:
    @patch("system_monitor.HAS_PSUTIL", True)
    @patch("system_monitor._psutil")
    def test_no_battery_returns_minus_one(self, mock_psutil):
        mock_psutil.sensors_battery.return_value = None
        pct, watts, charging = system_monitor.battery_info()
        assert pct == -1.0
        assert charging is False

    @patch("system_monitor.HAS_PSUTIL", True)
    @patch("system_monitor._psutil")
    def test_battery_present(self, mock_psutil):
        batt = MagicMock(percent=87.0, power_plugged=True)
        mock_psutil.sensors_battery.return_value = batt
        pct, watts, charging = system_monitor.battery_info()
        assert pct == 87.0
        assert charging is True
