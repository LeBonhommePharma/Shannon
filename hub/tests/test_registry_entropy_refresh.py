"""Registry entropy must not freeze on process-attach status spam."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from gate_scores import should_refresh_registry_entropy


class TestShouldRefreshRegistryEntropy:
    def test_result_refreshes(self):
        assert should_refresh_registry_entropy("result", {"cf_value": -3.2})

    def test_code_suggestion_refreshes(self):
        assert should_refresh_registry_entropy("code_suggestion", {})

    def test_benchmark_update_refreshes(self):
        assert should_refresh_registry_entropy("benchmark_update", {"completed": 1})

    def test_alert_and_ask_refresh(self):
        assert should_refresh_registry_entropy("alert", {"message": "x"})
        assert should_refresh_registry_entropy("approval_needed", {"prompt": "ok?"})

    def test_cmd_d_ingest_does_not_refresh(self):
        # This is the stuck-2.38 path: identical "Working in Ghostty" forever.
        assert not should_refresh_registry_entropy(
            "status",
            {"event": "ingest", "source": "cmd_d", "text": "Working in Ghostty"},
        )
        assert not should_refresh_registry_entropy(
            "status",
            {"source": "process_attach", "text": "Working in Ghostty"},
        )

    def test_tiny_status_is_heartbeat(self):
        assert not should_refresh_registry_entropy("status", {"message": "ok"})
        assert not should_refresh_registry_entropy("status", {"text": "hi"})

    def test_substantive_status_refreshes(self):
        assert should_refresh_registry_entropy(
            "status",
            {"message": "Docking target 1ACJ — simulation 4/10 complete"},
        )
