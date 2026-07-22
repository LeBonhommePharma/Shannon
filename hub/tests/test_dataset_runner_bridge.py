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
        # Direct JSON files are returned as-is (no cf/rmsd normalisation) --
        # only the legacy text format gets alias keys like best_cf/best_rmsd.
        f = tmp_path / "1ACJ.result"
        f.write_text(json.dumps({"cf": -3.217, "rmsd": 1.38, "target": "1ACJ"}))
        parsed = bridge._parse_result_file(f)
        assert parsed["cf"] == pytest.approx(-3.217)
        assert parsed["rmsd"] == pytest.approx(1.38)
        assert parsed["target"] == "1ACJ"

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
        # pose_file is only stamped on the legacy text-parsing path.
        f = tmp_path / "target.result"
        f.write_text("cf_score: -1.0\n")
        parsed = bridge._parse_result_file(f)
        assert parsed["pose_file"] == str(f)


class TestUpsertBenchmarkStateJsonBlob:
    def test_upsert_inserts_row_with_state_json(self, tmp_path):
        db_path = tmp_path / "agent_hub.db"
        con = bridge._open_db(db_path)
        state = {"cf": -3.217, "rmsd": 1.38, "target": "1ACJ"}
        bridge._upsert_benchmark(con, "dataset_runner", 50, state)

        row = con.execute(
            "SELECT progress, state_json FROM benchmark_state WHERE agent_id=?",
            ("dataset_runner",),
        ).fetchone()
        assert row[0] == 50
        blob = json.loads(row[1])
        assert blob["cf"] == pytest.approx(-3.217)
        assert blob["target"] == "1ACJ"
        con.close()

    def test_upsert_updates_existing_row(self, tmp_path):
        db_path = tmp_path / "agent_hub.db"
        con = bridge._open_db(db_path)
        bridge._upsert_benchmark(con, "dataset_runner", 10, {"cf": -1.0})
        bridge._upsert_benchmark(con, "dataset_runner", 20, {"cf": -2.0})

        rows = con.execute(
            "SELECT progress FROM benchmark_state WHERE agent_id=?",
            ("dataset_runner",),
        ).fetchall()
        assert len(rows) == 1
        assert rows[0][0] == 20
        con.close()

    def test_upsert_logs_activity_event(self, tmp_path):
        db_path = tmp_path / "agent_hub.db"
        con = bridge._open_db(db_path)
        bridge._upsert_benchmark(con, "dataset_runner", 42,
                                  {"cf": -3.217, "rmsd": 1.38, "target": "1ACJ"})
        row = con.execute(
            "SELECT event_type, agent_id, payload FROM agent_activity"
        ).fetchone()
        assert row[0] == "tool_call"
        assert row[1] == "dataset_runner"
        assert "CF=-3.217" in row[2]
        con.close()


class TestDatasetRunnerWatcherTick:
    def test_tick_picks_best_cf_and_updates_db(self, tmp_path):
        results_dir = tmp_path / "results"
        results_dir.mkdir()
        (results_dir / "a.result").write_text(json.dumps({"cf": -1.0, "target": "AAAA"}))
        (results_dir / "b.result").write_text(json.dumps({"cf": -5.0, "target": "BBBB"}))

        watcher = bridge.DatasetRunnerWatcher(
            results_dir=results_dir,
            agent_id="dataset_runner",
            db_path=tmp_path / "agent_hub.db",
        )
        watcher._total = 2
        watcher._tick()

        row = watcher._db().execute(
            "SELECT state_json FROM benchmark_state WHERE agent_id=?",
            ("dataset_runner",),
        ).fetchone()
        blob = json.loads(row[0])
        assert blob["cf"] == pytest.approx(-5.0)  # lower CF = better pose = chosen as best

    def test_tick_no_new_files_is_noop(self, tmp_path):
        results_dir = tmp_path / "results"
        results_dir.mkdir()
        watcher = bridge.DatasetRunnerWatcher(
            results_dir=results_dir,
            agent_id="dataset_runner",
            db_path=tmp_path / "agent_hub.db",
        )
        watcher._tick()  # no files, should not raise
