# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""Tests for the shannon-monitor CLI module."""

import argparse
import io
import json
import subprocess
import sys
import threading
import time

import numpy as np
import pytest

from shannon.cli import cmd_stdin, monitor_jsonl


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
    def test_quiet_mode_no_collapses(self):
        """Steady-state JSONL should report zero collapses."""
        records = [{"logits": list(np.zeros(8))} for _ in range(5)]
        stream = io.StringIO("\n".join(json.dumps(r) for r in records))
        count = monitor_jsonl(stream, field="logits", window_size=4, threshold=-3.2, quiet=True)
        assert count == 0

    def test_exit_code_on_collapse(self):
        """Collapse JSONL should report at least one collapse."""
        records = [{"logits": list(np.zeros(1024))} for _ in range(10)]
        spike = list(np.full(1024, -100.0))
        spike[0] = 100.0
        records.append({"logits": spike})
        stream = io.StringIO("\n".join(json.dumps(r) for r in records))
        count = monitor_jsonl(stream, field="logits", window_size=4, threshold=-3.0, quiet=True)
        assert count >= 1


# ── The path `shannon-monitor stdin` actually runs ───────────────────────────
#
# Everything above exercises monitor_jsonl(), which main() never dispatches to.
# The shipped `stdin` subcommand runs cmd_stdin(), which had no coverage at all
# -- which is how the stdout buffering defect below reached users.


class TestCmdStdin:
    """Covers cmd_stdin(), the function main() dispatches the `stdin` command to."""

    @staticmethod
    def _run(records, monkeypatch, capsys, fmt="text", window=4, threshold=-3.0):
        monkeypatch.setattr(
            sys, "stdin", io.StringIO("\n".join(json.dumps(r) for r in records))
        )
        cmd_stdin(argparse.Namespace(window=window, threshold=threshold, format=fmt))
        return capsys.readouterr()

    def test_emits_one_line_per_record(self, monkeypatch, capsys):
        records = [{"probs": [0.25, 0.25, 0.25, 0.25]} for _ in range(5)]
        out = self._run(records, monkeypatch, capsys).out
        assert len([ln for ln in out.splitlines() if ln.strip()]) == 5

    def test_accepts_all_three_input_fields(self, monkeypatch, capsys):
        lp = float(np.log(0.25))
        records = [
            {"probs": [0.25] * 4},
            {"logprobs": [lp] * 4},
            {"logits": [0.0] * 4},
        ]
        out = self._run(records, monkeypatch, capsys).out
        assert len([ln for ln in out.splitlines() if ln.strip()]) == 3

    def test_reports_collapse_on_entropy_drop(self, monkeypatch, capsys):
        records = [{"logits": list(np.zeros(1024))} for _ in range(10)]
        spike = list(np.full(1024, -100.0))
        spike[0] = 100.0
        records.append({"logits": spike})
        assert "COLLAPSE" in self._run(records, monkeypatch, capsys).out

    def test_csv_format_emits_header(self, monkeypatch, capsys):
        records = [{"probs": [0.5, 0.5]} for _ in range(3)]
        out = self._run(records, monkeypatch, capsys, fmt="csv").out
        assert out.splitlines()[0] == (
            "token_index,token,entropy,delta_h,collapse_score,collapsed"
        )

    def test_malformed_json_is_skipped_not_fatal(self, monkeypatch, capsys):
        monkeypatch.setattr(sys, "stdin", io.StringIO('{"probs": [0.5, 0.5]}\nNOT JSON\n'))
        cmd_stdin(argparse.Namespace(window=4, threshold=-3.0, format="text"))
        captured = capsys.readouterr()
        assert "Warning" in captured.err
        assert len([ln for ln in captured.out.splitlines() if ln.strip()]) == 1


class TestStdoutIsLineBuffered:
    """Regression guard for real-time monitoring over a pipe.

    Python block-buffers stdout when it is not a TTY. Because the tool is
    normally used as `producer | shannon-monitor stdin`, that buffering held
    every per-token line -- including the collapse alert -- until the producer
    closed the stream, so a collapse was only reported after the run it was
    meant to interrupt had finished.
    """

    def test_lines_arrive_while_the_pipe_is_still_open(self):
        proc = subprocess.Popen(
            [sys.executable, "-m", "shannon.cli", "stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        received: list[str] = []
        threading.Thread(
            target=lambda: [received.append(ln) for ln in proc.stdout], daemon=True
        ).start()
        try:
            for i in range(3):
                proc.stdin.write(json.dumps({"probs": [0.25] * 4, "token": f"t{i}"}) + "\n")
                proc.stdin.flush()
                time.sleep(0.25)
            time.sleep(0.6)
            # stdin is deliberately still open. Under block buffering this is 0.
            assert len(received) == 3, (
                f"expected 3 lines while the pipe was open, got {len(received)} - "
                "stdout is block-buffered, so live collapse alerts are withheld "
                "until the producer closes the stream"
            )
        finally:
            proc.stdin.close()
            proc.wait(timeout=10)
