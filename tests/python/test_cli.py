# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""Tests for the shannon-monitor CLI module."""

import io
import json

import numpy as np
import pytest

from shannon_entropy.cli import main, monitor_jsonl


# ── monitor_jsonl ────────────────────────────────────────────────────────────


class TestMonitorJsonl:
    def _make_stream(self, records: list[dict]) -> io.StringIO:
        lines = [json.dumps(r) for r in records]
        return io.StringIO("\n".join(lines))

    def test_logits_field(self):
        """Should process records with a 'logits' field."""
        records = [{"logits": list(np.zeros(8))} for _ in range(10)]
        stream = self._make_stream(records)
        count = monitor_jsonl(stream, field="logits", window_size=4, threshold=-3.2, quiet=True)
        assert count == 0

    def test_probs_field(self):
        """Should process records with a 'probs' field."""
        records = [{"probs": [0.25, 0.25, 0.25, 0.25]} for _ in range(10)]
        stream = self._make_stream(records)
        count = monitor_jsonl(stream, field="probs", window_size=4, threshold=-3.2, quiet=True)
        assert count == 0

    def test_logprobs_field(self):
        """Should process records with a 'logprobs' field."""
        lp = float(np.log(0.25))
        records = [{"logprobs": [lp, lp, lp, lp]} for _ in range(10)]
        stream = self._make_stream(records)
        count = monitor_jsonl(
            stream, field="logprobs", window_size=4, threshold=-3.2, quiet=True
        )
        assert count == 0

    def test_collapse_detected(self):
        """Should detect a collapse when entropy suddenly drops."""
        # High-entropy records (uniform over 1024 logits)
        records = [{"logits": list(np.zeros(1024))} for _ in range(10)]
        # Low-entropy record (single dominant logit)
        spike = list(np.full(1024, -100.0))
        spike[0] = 100.0
        records.append({"logits": spike})

        stream = self._make_stream(records)
        count = monitor_jsonl(stream, field="logits", window_size=4, threshold=-3.0, quiet=True)
        assert count >= 1

    def test_missing_field_skipped(self):
        """Records without the target field should be silently skipped."""
        records = [{"other_field": [1.0, 2.0]}, {"logits": [0.0, 0.0, 0.0, 0.0]}]
        stream = self._make_stream(records)
        count = monitor_jsonl(stream, field="logits", window_size=4, threshold=-3.2, quiet=True)
        assert count == 0

    def test_malformed_json_skipped(self):
        """Malformed JSON lines should be skipped with a warning."""
        stream = io.StringIO('not valid json\n{"logits": [0.0, 0.0, 0.0, 0.0]}\n')
        count = monitor_jsonl(stream, field="logits", window_size=4, threshold=-3.2, quiet=True)
        assert count == 0

    def test_blank_lines_skipped(self):
        """Blank lines should be silently skipped."""
        stream = io.StringIO('\n\n{"logits": [0.0, 0.0]}\n\n')
        count = monitor_jsonl(stream, field="logits", window_size=4, threshold=-3.2, quiet=True)
        assert count == 0

    def test_verbose_output(self, capsys):
        """Non-quiet mode should print per-token output."""
        records = [{"logits": [0.0, 0.0, 0.0, 0.0]}]
        stream = self._make_stream(records)
        monitor_jsonl(stream, field="logits", window_size=4, threshold=-3.2, quiet=False)
        captured = capsys.readouterr()
        assert "token=" in captured.out
        assert "H=" in captured.out


# ── main() CLI entrypoint ───────────────────────────────────────────────────


class TestMainCli:
    def test_quiet_mode_no_collapses(self, tmp_path, capsys, monkeypatch):
        """Quiet mode should print just the collapse count."""
        jsonl_file = tmp_path / "test.jsonl"
        records = [{"logits": list(np.zeros(8))} for _ in range(5)]
        jsonl_file.write_text("\n".join(json.dumps(r) for r in records))

        monkeypatch.setattr(
            "sys.argv", ["shannon-monitor", str(jsonl_file), "-q", "-w", "4"]
        )
        with pytest.raises(SystemExit) as exc_info:
            main()
        assert exc_info.value.code == 0

        captured = capsys.readouterr()
        assert captured.out.strip() == "0"

    def test_exit_code_on_collapse(self, tmp_path, monkeypatch):
        """Should exit with code 1 when collapses are detected."""
        records = [{"logits": list(np.zeros(1024))} for _ in range(10)]
        spike = list(np.full(1024, -100.0))
        spike[0] = 100.0
        records.append({"logits": spike})

        jsonl_file = tmp_path / "collapse.jsonl"
        jsonl_file.write_text("\n".join(json.dumps(r) for r in records))

        monkeypatch.setattr(
            "sys.argv",
            ["shannon-monitor", str(jsonl_file), "-q", "-w", "4", "-t", "-3.0"],
        )
        with pytest.raises(SystemExit) as exc_info:
            main()
        assert exc_info.value.code == 1
