"""DatasetRunner bridge: parse, gate-compatible upsert, multi-result progress churn."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

TOOLS_DIR = Path(__file__).resolve().parent.parent / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import dataset_runner_bridge as bridge


class TestParseResultFile:
    def test_parses_json_result_file(self, tmp_path):
        f = tmp_path / "1ACJ.result"
        f.write_text(json.dumps({"cf": -3.217, "rmsd": 1.38, "target": "1ACJ"}))
        parsed = bridge._parse_result_file(f)
        assert parsed["cf"] == pytest.approx(-3.217)
        assert parsed["rmsd"] == pytest.approx(1.38)
        assert parsed["target"] == "1ACJ"
        # JSON path now normalises best_* aliases for AuditDB / UI.
        assert parsed["best_cf"] == pytest.approx(-3.217)
        assert parsed["best_rmsd"] == pytest.approx(1.38)

    def test_parses_legacy_text_result_file(self, tmp_path):
        f = tmp_path / "1SG0_pose1.result"
        f.write_text("CF Score: -187.3\nRMSD to Ref: 1.14\n")
        parsed = bridge._parse_result_file(f)
        assert parsed["cf"] == pytest.approx(-187.3)
        assert parsed["best_cf"] == pytest.approx(-187.3)
        assert parsed["rmsd"] == pytest.approx(1.14)
        assert parsed["best_rmsd"] == pytest.approx(1.14)

    def test_infers_target_from_filename(self, tmp_path):
        f = tmp_path / "1SG0_pose1.result"
        f.write_text("cf_score: -1.0\n")
        parsed = bridge._parse_result_file(f)
        assert parsed["target"] == "1SG0"

    def test_pose_file_path_recorded_for_text_format(self, tmp_path):
        f = tmp_path / "target.result"
        f.write_text("cf_score: -1.0\n")
        parsed = bridge._parse_result_file(f)
        assert parsed["pose_file"] == str(f)


class TestUpsertBenchmarkStateJsonBlob:
    def test_upsert_inserts_row_with_state_json(self, tmp_path):
        db_path = tmp_path / "agent_hub.db"
        con = bridge._open_db(db_path)
        state = {"cf": -3.217, "rmsd": 1.38, "target": "1ACJ"}
        bridge._upsert_benchmark(
            con, "dataset_runner", 50, state, task_id="flexaidds_astex_t1"
        )

        row = con.execute(
            "SELECT completed, state_json, task_id, best_cf, active_target "
            "FROM benchmark_state WHERE task_id=?",
            ("flexaidds_astex_t1",),
        ).fetchone()
        assert row is not None
        assert row[0] == 50  # completed = progress 0–100
        blob = json.loads(row[1])
        assert blob["cf"] == pytest.approx(-3.217)
        assert blob["target"] == "1ACJ"
        assert row[2] == "flexaidds_astex_t1"
        assert row[3] == pytest.approx(-3.217)
        assert row[4] == "1ACJ"
        con.close()

    def test_upsert_appends_progress_rows(self, tmp_path):
        """Gate schema is append-only; latest row carries higher progress."""
        db_path = tmp_path / "agent_hub.db"
        con = bridge._open_db(db_path)
        tid = "flexaidds_red_pair_t1"
        bridge._upsert_benchmark(con, "dataset_runner", 10, {"cf": -1.0}, task_id=tid)
        bridge._upsert_benchmark(con, "dataset_runner", 20, {"cf": -2.0}, task_id=tid)

        rows = con.execute(
            "SELECT completed FROM benchmark_state WHERE task_id=? ORDER BY id",
            (tid,),
        ).fetchall()
        assert len(rows) == 2
        assert rows[0][0] == 10
        assert rows[1][0] == 20
        con.close()

    def test_upsert_logs_activity_event(self, tmp_path):
        db_path = tmp_path / "agent_hub.db"
        con = bridge._open_db(db_path)
        bridge._upsert_benchmark(
            con,
            "dataset_runner",
            42,
            {"cf": -3.217, "rmsd": 1.38, "target": "1ACJ"},
            task_id="t_act",
        )
        row = con.execute(
            "SELECT event_type, agent_id, event_label, event_output FROM agent_activity"
        ).fetchone()
        assert row[0] == "tool_call"
        assert row[1] == "dataset_runner"
        assert "1ACJ" in (row[2] or "")
        assert "CF=-3.217" in (row[3] or "")
        con.close()


class TestDatasetRunnerWatcherTick:
    def test_tick_picks_best_cf_and_updates_db(self, tmp_path):
        results_dir = tmp_path / "results"
        results_dir.mkdir()
        (results_dir / "a.result").write_text(
            json.dumps({"cf": -1.0, "target": "AAAA"})
        )
        (results_dir / "b.result").write_text(
            json.dumps({"cf": -5.0, "target": "BBBB"})
        )

        watcher = bridge.DatasetRunnerWatcher(
            results_dir=results_dir,
            agent_id="dataset_runner",
            db_path=tmp_path / "agent_hub.db",
            task_id="flexaidds_astex_best",
            total=2,
        )
        watcher._tick()

        row = watcher._db().execute(
            "SELECT state_json, completed, best_cf FROM benchmark_state "
            "WHERE task_id=? ORDER BY id DESC LIMIT 1",
            ("flexaidds_astex_best",),
        ).fetchone()
        blob = json.loads(row[0])
        assert blob["cf"] == pytest.approx(-5.0)
        assert row[1] == 100  # 2/2
        assert row[2] == pytest.approx(-5.0)
        watcher.close()

    def test_tick_no_new_files_is_noop(self, tmp_path):
        results_dir = tmp_path / "results"
        results_dir.mkdir()
        watcher = bridge.DatasetRunnerWatcher(
            results_dir=results_dir,
            agent_id="dataset_runner",
            db_path=tmp_path / "agent_hub.db",
        )
        watcher._tick()  # no files, should not raise
        watcher.close()


class TestMultiResultProgressChurn:
    """Computation churn: sequential results advance hub progress/state_json."""

    def test_sequential_ticks_advance_progress(self, tmp_path):
        results_dir = tmp_path / "results"
        results_dir.mkdir()
        db = tmp_path / "agent_hub.db"
        tid = "flexaidds_astex_churn"
        watcher = bridge.DatasetRunnerWatcher(
            results_dir=results_dir,
            agent_id="dataset_runner",
            db_path=db,
            task_id=tid,
            total=4,
        )

        (results_dir / "1ACJ.result").write_text(
            json.dumps({"cf": -2.0, "rmsd": 1.5, "target": "1ACJ"})
        )
        watcher._tick()
        p1 = watcher._db().execute(
            "SELECT completed FROM benchmark_state WHERE task_id=? ORDER BY id DESC LIMIT 1",
            (tid,),
        ).fetchone()[0]
        assert p1 == 25  # 1/4

        (results_dir / "1SG0.result").write_text(
            json.dumps({"cf": -4.5, "rmsd": 1.1, "target": "1SG0"})
        )
        watcher._tick()
        p2 = watcher._db().execute(
            "SELECT completed, best_cf, active_target, state_json "
            "FROM benchmark_state WHERE task_id=? ORDER BY id DESC LIMIT 1",
            (tid,),
        ).fetchone()
        assert p2[0] == 50  # 2/4
        assert p2[0] > p1
        assert p2[1] == pytest.approx(-4.5)  # global best (lower CF)
        assert p2[2] == "1SG0"
        blob = json.loads(p2[3])
        assert blob["done"] == 2
        assert blob["total"] == 4
        assert "cf" in blob and "rmsd" in blob

        (results_dir / "2XYZ.result").write_text(
            json.dumps({"cf": -1.0, "rmsd": 2.0, "target": "2XYZ"})
        )
        watcher._tick()
        p3 = watcher._db().execute(
            "SELECT completed, best_cf FROM benchmark_state "
            "WHERE task_id=? ORDER BY id DESC LIMIT 1",
            (tid,),
        ).fetchone()
        assert p3[0] == 75  # 3/4
        # Worse CF must not replace global best
        assert p3[1] == pytest.approx(-4.5)
        watcher.close()

    def test_ingest_once_public_helper(self, tmp_path):
        results_dir = tmp_path / "results"
        results_dir.mkdir()
        for name, cf in (("AAAA.result", -1.0), ("BBBB.result", -3.0), ("CCCC.result", -2.0)):
            (results_dir / name).write_text(
                json.dumps({"cf": cf, "target": name[:4]})
            )
        # Manifest pins total so progress is deterministic
        (results_dir / "dataset.txt").write_text("AAAA\nBBBB\nCCCC\nDDDD\nEEEE\n")

        summary = bridge.ingest_results(
            results_dir,
            agent_id="dataset_runner",
            db_path=tmp_path / "agent_hub.db",
            task_id="flexaidds_astex_once",
            total=5,
        )
        assert summary["ok"] is True
        assert summary["done"] == 3
        assert summary["total"] == 5
        assert summary["progress"] == 60  # 3/5
        assert summary["best_cf"] == pytest.approx(-3.0)
        assert summary["agent_id"] == "dataset_runner"

        con = bridge._open_db(tmp_path / "agent_hub.db")
        row = con.execute(
            "SELECT completed, state_json FROM benchmark_state "
            "WHERE task_id=? ORDER BY id DESC LIMIT 1",
            ("flexaidds_astex_once",),
        ).fetchone()
        assert row[0] == 60
        assert json.loads(row[1])["best_cf"] == pytest.approx(-3.0)
        con.close()

    def test_cli_once_json(self, tmp_path, capsys):
        results_dir = tmp_path / "results"
        results_dir.mkdir()
        (results_dir / "1ACJ.result").write_text(
            json.dumps({"cf": -3.2, "rmsd": 1.4, "target": "1ACJ"})
        )
        db = tmp_path / "hub.db"
        rc = bridge.main(
            [
                "--results-dir",
                str(results_dir),
                "--db",
                str(db),
                "--task",
                "flexaidds_cli_once",
                "--total",
                "2",
                "--once",
                "--json",
            ]
        )
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert data["ok"] is True
        assert data["done"] == 1
        assert data["progress"] == 50
        assert data["best_cf"] == pytest.approx(-3.2)
