"""Tests for tools/dataset_runner_bridge.py."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

import dataset_runner_bridge as bridge  # noqa: E402


class TestOpenDb:
    def test_creates_tables(self, tmp_path):
        con = bridge._open_db(tmp_path / "hub.db")
        cur = con.execute("SELECT name FROM sqlite_master WHERE type='table'")
        names = {row[0] for row in cur.fetchall()}
        assert "benchmark_state" in names
        assert "agent_activity" in names
        con.close()


class TestUpsertBenchmark:
    def test_insert_and_update(self, tmp_path):
        con = bridge._open_db(tmp_path / "hub.db")
        bridge._upsert_benchmark(con, "dataset_runner", 10, {"cf": -180.0, "target": "1SG0"})
        row = con.execute(
            "SELECT progress, state_json FROM benchmark_state WHERE agent_id=?",
            ("dataset_runner",),
        ).fetchone()
        assert row[0] == 10
        assert json.loads(row[1])["cf"] == -180.0

        bridge._upsert_benchmark(con, "dataset_runner", 20, {"cf": -190.0, "target": "1SG0"})
        row = con.execute(
            "SELECT progress FROM benchmark_state WHERE agent_id=?",
            ("dataset_runner",),
        ).fetchone()
        assert row[0] == 20
        con.close()


class TestParseResultFile:
    def test_parse_json_result(self, tmp_path):
        f = tmp_path / "1SG0_pose1.result"
        f.write_text(json.dumps({"cf": -187.3, "rmsd": 1.14, "target": "1SG0"}))
        parsed = bridge._parse_result_file(f)
        assert parsed["cf"] == -187.3
        assert parsed["target"] == "1SG0"

    def test_parse_text_result_with_aliases(self, tmp_path):
        f = tmp_path / "2ABC_pose2.result"
        f.write_text("cf_score: -150.5\nrmsd_to_ref: 2.0\n")
        parsed = bridge._parse_result_file(f)
        assert parsed["cf"] == -150.5
        assert parsed["best_cf"] == -150.5
        assert parsed["rmsd"] == 2.0
        assert parsed["best_rmsd"] == 2.0
        assert parsed["target"] == "2ABC"

    def test_parse_result_infers_target_from_filename(self, tmp_path):
        f = tmp_path / "3XYZ_pose1.result"
        f.write_text("cf: -100.0\n")
        parsed = bridge._parse_result_file(f)
        assert parsed["target"] == "3XYZ"


class TestScanResults:
    def test_scan_finds_matching_extensions(self, tmp_path):
        (tmp_path / "a.result").write_text("cf: -1\n")
        (tmp_path / "b.json").write_text("{}")
        (tmp_path / "c.txt").write_text("ignored")
        files = bridge._scan_results(tmp_path)
        names = {p.name for p in files}
        assert "a.result" in names
        assert "b.json" in names
        assert "c.txt" not in names


class TestDatasetRunnerWatcher:
    def test_init_sets_paths(self, tmp_path):
        w = bridge.DatasetRunnerWatcher(
            results_dir=tmp_path / "results",
            agent_id="dataset_runner",
            db_path=tmp_path / "hub.db",
        )
        assert w.agent_id == "dataset_runner"
        assert w.results_dir == tmp_path / "results"
