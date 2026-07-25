"""Tests for hub/system_monitor.py.

Hermeticity contract for this file
----------------------------------
Every test here must produce the same verdict on a machine WITH psutil
installed and on a machine WITHOUT it. psutil is an optional dependency
(see `hub/requirements.txt` and the `dev` extra in `pyproject.toml`), so the
suite has to be honest in both worlds:

  * `TestPsutilBinding`      — pins the module invariant that makes the rest
                               possible: `_psutil` is always bound.
  * `TestMetricPollingWithMockPsutil`
                             — drives the psutil branch through an injected
                               fake. Runs unconditionally, psutil or not.
  * `TestSubprocessFallback` — drives the no-psutil branch through canned
                               tool output. Runs unconditionally.
  * `TestRealPsutil`         — the only conditional class. Skipped with a
                               visible reason when psutil is genuinely absent,
                               never skipped when it is installed.

No test may touch the real clock, the network, the user's home directory, or
a live daemon.
"""

import os
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
import system_monitor as sm

# ── Canned helper-tool output ────────────────────────────────────────────────
# Captured verbatim from macOS 27 so the parsers are tested against the shape
# the real tools emit, not against a shape invented to match the parser.

TOP_OUTPUT = "Processes: 500 total\nCPU usage: 12.50% user, 7.50% sys, 80.00% idle\n"
TOP_OUTPUT_PEGGED = (
    "Processes: 823 total, 4 running\n"
    "CPU usage: 86.38% user, 13.61% sys, 0.0% idle \n"
)
VM_STAT_OUTPUT = (
    "Mach Virtual Memory Statistics: (page size of 4096 bytes)\n"
    "Pages free:                    100000.\n"
    "Pages active:                  1000000.\n"
    "Pages wired down:              500000.\n"
    "Pages occupied by compressor:  400000.\n"
)
MEMSIZE_OUTPUT = "17179869184\n"          # 16 GiB
DF_OUTPUT = (
    "Filesystem 1024-blocks      Used Available Capacity  Mounted on\n"
    "/dev/disk3s5   488245288 100000000 300000000    26%    /\n"
)
PMSET_BATT_DISCHARGING = (
    "Now drawing from 'Battery Power'\n"
    " -InternalBattery-0 (id=1234)\t79%; discharging; 3:21 remaining present: true\n"
)
PMSET_BATT_CHARGING = (
    "Now drawing from 'AC Power'\n"
    " -InternalBattery-0 (id=1234)\t79%; charging; 1:02 remaining present: true\n"
)
PMSET_BATT_NOT_CHARGING_ON_AC = (
    "Now drawing from 'AC Power'\n"
    " -InternalBattery-0 (id=1234)\t100%; AC attached; not charging present: true\n"
)


def _tool_output(mapping: dict[str, str]):
    """A `subprocess.check_output` stand-in keyed on the executable basename.

    Any command not in `mapping` raises FileNotFoundError, so a test that
    forgets to stub a tool fails loudly instead of shelling out for real.
    """

    def fake(argv, *args, **kwargs):
        try:
            name = os.path.basename(argv[0])
        except (TypeError, IndexError):  # pragma: no cover - defensive
            raise FileNotFoundError(argv) from None
        if name not in mapping:
            raise FileNotFoundError(name)
        return mapping[name]

    return fake


@pytest.fixture
def no_psutil(monkeypatch):
    """Force the subprocess fallback regardless of what is installed."""
    monkeypatch.setattr(sm, "HAS_PSUTIL", False)
    monkeypatch.delenv("SHANNON_MONITOR_PSUTIL", raising=False)
    return None


@pytest.fixture
def fake_psutil(monkeypatch):
    """Force the psutil branch, backed by a caller-populated fake module."""
    fake = SimpleNamespace()
    monkeypatch.setattr(sm, "HAS_PSUTIL", True)
    monkeypatch.setattr(sm, "_psutil", fake)
    monkeypatch.delenv("SHANNON_MONITOR_PSUTIL", raising=False)
    return fake


class TestSchema:
    def test_open_db_creates_table(self, tmp_path):
        con = sm.open_db(tmp_path / "agent_hub.db")
        cur = con.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = {row[0] for row in cur.fetchall()}
        assert "system_metrics" in tables
        con.close()

    def test_open_db_accepts_a_string_path(self, tmp_path):
        # The CLI hands over a Path, but callers embedding the module pass str.
        con = sm.open_db(str(tmp_path / "nested" / "agent_hub.db"))
        assert (tmp_path / "nested" / "agent_hub.db").exists()
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


class TestPsutilBinding:
    """psutil is optional, so `_psutil` must exist either way.

    Regression: the name used to be bound only inside the successful `import`
    branch. On a machine without psutil the attribute was absent, and
    `mock.patch` refuses to patch a missing attribute — so every psutil test in
    this file died with AttributeError and got waved off as "environmental".
    The clean machine is exactly where the branch most needs covering.
    """

    def test_psutil_attribute_always_exists(self):
        assert hasattr(sm, "_psutil"), "_psutil must be bound even when the import fails"

    def test_flag_agrees_with_binding(self):
        assert sm.HAS_PSUTIL == (sm._psutil is not None)

    def test_collectors_degrade_when_flag_and_module_disagree(self, monkeypatch):
        # Fail closed: a caller forcing HAS_PSUTIL=True with no module must get
        # the subprocess fallback, not a NameError out of the polling loop.
        monkeypatch.setattr(sm, "HAS_PSUTIL", True)
        monkeypatch.setattr(sm, "_psutil", None)
        assert sm.use_psutil() is False
        with patch("subprocess.check_output", side_effect=FileNotFoundError()):
            assert sm.cpu_percent() == 0.0
            assert sm.ram_info() == (0.0, 0.0)
            assert sm.disk_info() == (0.0, 0.0)
            assert sm.battery_info() == (-1.0, 0.0, False)


class TestPsutilKnob:
    """SHANNON_MONITOR_PSUTIL — safe default on, explicit opt-out."""

    def test_default_is_on_when_psutil_present(self, fake_psutil):
        assert sm.use_psutil() is True

    @pytest.mark.parametrize("value", ["0", "false", "FALSE", "no", "off", " off "])
    def test_falsey_values_force_the_fallback(self, fake_psutil, monkeypatch, value):
        monkeypatch.setenv("SHANNON_MONITOR_PSUTIL", value)
        assert sm.use_psutil() is False

    @pytest.mark.parametrize("value", ["1", "true", "yes", "on"])
    def test_truthy_values_keep_psutil(self, fake_psutil, monkeypatch, value):
        monkeypatch.setenv("SHANNON_MONITOR_PSUTIL", value)
        assert sm.use_psutil() is True

    @pytest.mark.parametrize("value", ["", "maybe", "2", "yolo"])
    def test_unrecognised_values_keep_the_default(self, fake_psutil, monkeypatch, value):
        monkeypatch.setenv("SHANNON_MONITOR_PSUTIL", value)
        assert sm.use_psutil() is True

    def test_knob_cannot_conjure_psutil_when_absent(self, monkeypatch):
        monkeypatch.setattr(sm, "HAS_PSUTIL", False)
        monkeypatch.setattr(sm, "_psutil", None)
        monkeypatch.setenv("SHANNON_MONITOR_PSUTIL", "1")
        assert sm.use_psutil() is False

    def test_knob_routes_cpu_percent_to_the_fallback(self, fake_psutil, monkeypatch):
        fake_psutil.cpu_percent = MagicMock(return_value=42.0)
        monkeypatch.setenv("SHANNON_MONITOR_PSUTIL", "0")
        with patch("subprocess.check_output", _tool_output({"top": TOP_OUTPUT})):
            assert sm.cpu_percent() == pytest.approx(20.0)
        fake_psutil.cpu_percent.assert_not_called()


class TestMetricPollingWithMockPsutil:
    """The psutil branch, driven by an injected fake. Runs in both worlds."""

    def test_cpu_percent_uses_psutil_when_available(self, fake_psutil):
        fake_psutil.cpu_percent = MagicMock(return_value=42.0)
        assert sm.cpu_percent() == 42.0
        fake_psutil.cpu_percent.assert_called_once()

    def test_ram_info_uses_psutil_when_available(self, fake_psutil):
        fake_psutil.virtual_memory = MagicMock(
            return_value=SimpleNamespace(used=8_000_000_000, total=16_000_000_000)
        )
        used, total = sm.ram_info()
        assert used == pytest.approx(8.0)
        assert total == pytest.approx(16.0)

    def test_disk_info_uses_psutil_when_available(self, fake_psutil):
        fake_psutil.disk_usage = MagicMock(
            return_value=SimpleNamespace(used=100_000_000_000, total=500_000_000_000)
        )
        used, total = sm.disk_info()
        assert used == pytest.approx(100.0)
        assert total == pytest.approx(500.0)

    def test_battery_info_uses_psutil_when_available(self, fake_psutil):
        fake_psutil.sensors_battery = MagicMock(
            return_value=SimpleNamespace(percent=77.0, power_plugged=True)
        )
        pct, watts, charging = sm.battery_info()
        assert pct == pytest.approx(77.0)
        assert charging is True

    def test_battery_info_no_battery_returns_negative_one(self, fake_psutil):
        fake_psutil.sensors_battery = MagicMock(return_value=None)
        pct, watts, charging = sm.battery_info()
        assert pct == -1.0
        assert charging is False

    def test_cpu_percent_falls_back_without_psutil(self, no_psutil):
        with patch("subprocess.check_output", side_effect=FileNotFoundError()):
            assert sm.cpu_percent() == 0.0

    # ── psutil raising mid-poll must not take the monitor down ──────────────

    def test_psutil_exception_is_contained(self, fake_psutil):
        fake_psutil.cpu_percent = MagicMock(side_effect=RuntimeError("sensor gone"))
        fake_psutil.virtual_memory = MagicMock(side_effect=RuntimeError("sensor gone"))
        fake_psutil.disk_usage = MagicMock(side_effect=RuntimeError("sensor gone"))
        fake_psutil.sensors_battery = MagicMock(side_effect=RuntimeError("sensor gone"))
        assert sm.cpu_percent() == 0.0
        assert sm.ram_info() == (0.0, 0.0)
        assert sm.disk_info() == (0.0, 0.0)
        assert sm.battery_info() == (-1.0, 0.0, False)


class TestSubprocessFallback:
    """The no-psutil branch, driven by canned tool output. Runs in both worlds."""

    def test_cpu_percent_parses_top(self, no_psutil):
        with patch("subprocess.check_output", _tool_output({"top": TOP_OUTPUT})):
            assert sm.cpu_percent() == pytest.approx(20.0)   # 12.5 user + 7.5 sys

    def test_cpu_percent_counts_the_user_share(self, no_psutil):
        """Regression: the `user` percentage was silently dropped.

        The parser split the line on "," and read token[0] of each segment.
        Segment 0 is "CPU usage: 86.38% user", whose first token is "CPU", so
        float() raised and the largest component vanished. A machine pegged at
        100% was reported to the HUD as 13.61% busy — the monitor's whole job,
        inverted.
        """
        with patch("subprocess.check_output", _tool_output({"top": TOP_OUTPUT_PEGGED})):
            value = sm.cpu_percent()
        assert value == pytest.approx(99.99), "user% must be counted, not dropped"

    def test_fallback_tools_are_invoked_by_absolute_path(self, no_psutil):
        """$PATH is ambient state; the fallback must not depend on it.

        On this very machine `top` is shadowed by a btop alias/shim whose
        output the parser cannot read. Pinning absolute paths keeps a PATH
        entry from redirecting the monitor to an arbitrary binary.
        """
        seen: list[str] = []

        def record(argv, *args, **kwargs):
            seen.append(argv[0])
            raise FileNotFoundError(argv[0])

        with patch("subprocess.check_output", record):
            sm.cpu_percent()
            sm.ram_info()
            sm.disk_info()
            sm.thermal_state()
            sm.battery_info()

        assert seen, "no tool was invoked"
        for argv0 in seen:
            assert os.path.isabs(argv0), f"{argv0!r} resolves through $PATH"
        assert sm.TOOL_TOP in seen and sm.TOOL_DF in seen and sm.TOOL_PMSET in seen

    def test_ram_info_parses_vm_stat_and_sysctl(self, no_psutil):
        with patch("subprocess.check_output",
                   _tool_output({"vm_stat": VM_STAT_OUTPUT, "sysctl": MEMSIZE_OUTPUT})):
            used, total = sm.ram_info()
        assert used == pytest.approx(1_900_000 * 4096 / 1e9)
        assert total == pytest.approx(17.179869184)

    def test_ram_info_refuses_when_sysctl_is_missing(self, no_psutil):
        # Without a total there is no reading — do not report a bare `used`
        # against a total of 0, which renders as infinite utilisation.
        with patch("subprocess.check_output", _tool_output({"vm_stat": VM_STAT_OUTPUT})):
            assert sm.ram_info() == (0.0, 0.0)

    def test_disk_info_parses_df(self, no_psutil):
        with patch("subprocess.check_output", _tool_output({"df": DF_OUTPUT})):
            used, total = sm.disk_info()
        assert used == pytest.approx(100.0)
        assert total == pytest.approx(488.245288)

    def test_thermal_state_nominal_when_pmset_silent(self, no_psutil):
        with patch("subprocess.check_output", _tool_output({"pmset": "No thermal warnings\n"})):
            assert sm.thermal_state() == 0

    @pytest.mark.parametrize("limit,expected", [(100, 0), (90, 1), (70, 2), (50, 3), (10, 3)])
    def test_thermal_state_grades_cpu_speed_limit(self, no_psutil, limit, expected):
        out = f"CPU_Scheduler_Limit \t= 100\nCPU_Speed_Limit \t= {limit}\n"
        with patch("subprocess.check_output", _tool_output({"pmset": out})):
            assert sm.thermal_state() == expected

    def test_battery_discharging_is_not_reported_as_charging(self, no_psutil):
        """Regression: `"charging" in "discharging"` is True.

        The old substring test flagged a draining battery as charging, so the
        HUD showed a machine on wall power while it was running the battery
        flat.
        """
        with patch("subprocess.check_output",
                   _tool_output({"pmset": PMSET_BATT_DISCHARGING})):
            pct, _watts, charging = sm.battery_info()
        assert pct == pytest.approx(79.0)
        assert charging is False

    def test_battery_charging_is_reported_as_charging(self, no_psutil):
        with patch("subprocess.check_output", _tool_output({"pmset": PMSET_BATT_CHARGING})):
            pct, _watts, charging = sm.battery_info()
        assert pct == pytest.approx(79.0)
        assert charging is True

    def test_battery_not_charging_on_ac_is_still_plugged_in(self, no_psutil):
        with patch("subprocess.check_output",
                   _tool_output({"pmset": PMSET_BATT_NOT_CHARGING_ON_AC})):
            pct, _watts, charging = sm.battery_info()
        assert pct == pytest.approx(100.0)
        assert charging is True

    @pytest.mark.parametrize(
        "collector,expected",
        [("cpu_percent", 0.0), ("ram_info", (0.0, 0.0)),
         ("disk_info", (0.0, 0.0)), ("battery_info", (-1.0, 0.0, False)),
         ("thermal_state", 0)],
    )
    def test_missing_tools_yield_no_reading(self, no_psutil, collector, expected):
        with patch("subprocess.check_output", side_effect=FileNotFoundError()):
            assert getattr(sm, collector)() == expected

    @pytest.mark.parametrize(
        "collector,expected",
        [("cpu_percent", 0.0), ("ram_info", (0.0, 0.0)),
         ("disk_info", (0.0, 0.0)), ("battery_info", (-1.0, 0.0, False)),
         ("thermal_state", 0)],
    )
    def test_timeouts_yield_no_reading(self, no_psutil, collector, expected):
        import subprocess as _sp
        with patch("subprocess.check_output", side_effect=_sp.TimeoutExpired("x", 1)):
            assert getattr(sm, collector)() == expected


class TestFailClosedOnMalformedInput:
    """Unparseable, absurd or hostile readings must refuse, never pass through."""

    @pytest.mark.parametrize("garbage", [
        "",
        "CPU usage: not-a-number user, junk sys, 80.00% idle\n",
        "\x00\x00\x00",
        "CPU usage: -50.0% user, -50.0% sys\n",
    ])
    def test_malformed_top_never_leaves_the_valid_range(self, no_psutil, garbage):
        with patch("subprocess.check_output", _tool_output({"top": garbage})):
            value = sm.cpu_percent()
        assert 0.0 <= value <= 100.0

    def test_absurd_cpu_reading_is_refused(self, fake_psutil):
        fake_psutil.cpu_percent = MagicMock(return_value=100_000.0)
        assert sm.cpu_percent() == 0.0

    @pytest.mark.parametrize("bad", [float("nan"), float("inf"), -1.0, None, "twelve"])
    def test_non_numeric_cpu_reading_is_refused(self, fake_psutil, bad):
        fake_psutil.cpu_percent = MagicMock(return_value=bad)
        assert sm.cpu_percent() == 0.0

    def test_used_greater_than_total_is_refused(self, fake_psutil):
        # Arithmetically impossible => bad parse. Refusing beats drawing >100%.
        fake_psutil.virtual_memory = MagicMock(
            return_value=SimpleNamespace(used=32_000_000_000, total=16_000_000_000)
        )
        assert sm.ram_info() == (0.0, 0.0)

    def test_zero_total_is_refused(self, fake_psutil):
        fake_psutil.disk_usage = MagicMock(
            return_value=SimpleNamespace(used=0, total=0)
        )
        assert sm.disk_info() == (0.0, 0.0)

    def test_battery_percent_out_of_range_is_refused(self, fake_psutil):
        fake_psutil.sensors_battery = MagicMock(
            return_value=SimpleNamespace(percent=900.0, power_plugged=False)
        )
        pct, _watts, charging = sm.battery_info()
        assert pct == -1.0
        assert charging is False

    def test_truncated_df_row_is_refused(self, no_psutil):
        with patch("subprocess.check_output", _tool_output({"df": "Filesystem\n/dev/disk3s5\n"})):
            assert sm.disk_info() == (0.0, 0.0)

    def test_oversized_tool_output_is_truncated_before_parsing(self, no_psutil):
        # A broken or hostile tool on PATH must not be able to balloon the
        # monitor's memory: cap the text before splitlines() sees it.
        flood = "x" * (sm.MAX_TOOL_OUTPUT_CHARS + 10_000)
        with patch("subprocess.check_output", _tool_output({"top": flood})):
            assert sm.cpu_percent() == 0.0

    def test_run_tool_caps_output_length(self):
        flood = "y" * (sm.MAX_TOOL_OUTPUT_CHARS * 2)
        with patch("subprocess.check_output", return_value=flood):
            out = sm._run_tool(["anything"], timeout=1)
        assert out is not None
        assert len(out) == sm.MAX_TOOL_OUTPUT_CHARS

    def test_run_tool_returns_none_on_non_string_output(self):
        # text=False elsewhere in the tree would hand back bytes; refuse it
        # rather than crash the parser half way through a poll.
        with patch("subprocess.check_output", return_value=b"bytes not str"):
            assert sm._run_tool(["anything"], timeout=1) is None


class TestPollLoop:
    """`run()` writes what the collectors returned — bounded, no wall clock."""

    def test_bounded_run_writes_one_row_per_poll(self, tmp_path, fake_psutil, monkeypatch):
        fake_psutil.cpu_percent = MagicMock(return_value=42.0)
        fake_psutil.virtual_memory = MagicMock(
            return_value=SimpleNamespace(used=8_000_000_000, total=16_000_000_000))
        fake_psutil.disk_usage = MagicMock(
            return_value=SimpleNamespace(used=100_000_000_000, total=500_000_000_000))
        fake_psutil.sensors_battery = MagicMock(
            return_value=SimpleNamespace(percent=77.0, power_plugged=True))
        monkeypatch.setattr(sm, "thermal_state", lambda: 2)
        monkeypatch.setattr(sm.time, "sleep", lambda _s: None)

        db = tmp_path / "agent_hub.db"
        sm.run(db, interval=0.0, max_polls=3)

        con = sm.open_db(db)
        rows = con.execute(
            "SELECT cpu_percent, ram_used_gb, ssd_total_gb, thermal_state, "
            "battery_pct, is_charging FROM system_metrics ORDER BY id"
        ).fetchall()
        con.close()
        assert len(rows) == 3
        assert rows[0] == (42.0, 8.0, 500.0, 2, 77.0, 1)

    def test_poll_errors_do_not_stop_the_loop(self, tmp_path, fake_psutil, monkeypatch):
        monkeypatch.setattr(sm, "cpu_percent", MagicMock(side_effect=RuntimeError("boom")))
        monkeypatch.setattr(sm.time, "sleep", lambda _s: None)
        db = tmp_path / "agent_hub.db"
        sm.run(db, interval=0.0, max_polls=2)      # must return, not raise
        con = sm.open_db(db)
        count = con.execute("SELECT COUNT(*) FROM system_metrics").fetchone()[0]
        con.close()
        assert count == 0                          # refused, not a bogus row


@pytest.mark.skipif(
    not sm.HAS_PSUTIL,
    reason="psutil not installed; install the `dev` extra (pip install -e '.[dev]') "
           "or hub/requirements.txt to exercise the real psutil path",
)
class TestRealPsutil:
    """The real psutil path, unmocked.

    This is the only conditionally-skipped class in the file, and CI installs
    psutil via the `dev` extra so it does not skip there. Assertions are
    invariants (types, ranges, internal consistency) rather than exact values,
    so the outcome does not depend on what the machine happens to be doing.
    """

    def test_real_psutil_is_the_module_we_bound(self):
        import psutil
        assert sm._psutil is psutil
        assert sm.use_psutil() is True

    def test_real_ram_info_is_self_consistent(self):
        used, total = sm.ram_info()
        assert total > 0.0, "a host with psutil always reports physical RAM"
        assert 0.0 <= used <= total

    def test_real_disk_info_is_self_consistent(self):
        used, total = sm.disk_info()
        assert total > 0.0
        assert 0.0 <= used <= total

    def test_real_battery_info_is_in_range(self):
        pct, watts, charging = sm.battery_info()
        assert pct == -1.0 or 0.0 <= pct <= 100.0
        assert isinstance(charging, bool)
        assert watts >= 0.0

    def test_real_cpu_percent_is_in_range(self):
        assert 0.0 <= sm.cpu_percent() <= 100.0
