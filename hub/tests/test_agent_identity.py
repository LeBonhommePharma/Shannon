"""Tests for shipped agent_identity catalog + status/ask reducers."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from agent_identity import (
    CORE_AGENT_IDS,
    IDENTITIES,
    ask_from_payload,
    core_identities,
    identity_for,
    label_for,
    resolve_ask,
    status_from_payload,
)


class TestCoreSixIdentities:
    def test_all_six_present(self):
        for aid in CORE_AGENT_IDS:
            assert aid in IDENTITIES, f"missing {aid}"
        ids = {i.id for i in core_identities()}
        assert ids == set(CORE_AGENT_IDS)

    def test_distinct_display_names_and_colors(self):
        names = [IDENTITIES[a].display_name for a in CORE_AGENT_IDS]
        assert len(names) == len(set(names))
        colors = [IDENTITIES[a].color_rgb for a in CORE_AGENT_IDS]
        assert len(colors) == len(set(colors))
        # Science ≠ Grok Build brand cues
        assert IDENTITIES["science"].emoji != IDENTITIES["grok_build"].emoji
        assert IDENTITIES["science"].system_image != IDENTITIES["grok_build"].system_image
        assert "Science" in IDENTITIES["science"].display_name
        assert "Grok" in IDENTITIES["grok_build"].display_name

    def test_each_core_agent_has_a_distinct_companion(self):
        pets = [IDENTITIES[a].pet for a in CORE_AGENT_IDS]
        assert len(pets) == len(set(pets)), f"duplicate companion animal: {pets}"
        # Glyphs must differ too, or the card gives two agents the same mark.
        symbols = [IDENTITIES[a].pet_symbol for a in CORE_AGENT_IDS]
        assert len(symbols) == len(set(symbols)), f"duplicate pet_symbol: {symbols}"
        assert IDENTITIES["science"].pet == "owl"
        assert IDENTITIES["claude_code"].pet == "fox"

    def test_companion_is_serialised_for_swift_interop(self):
        d = IDENTITIES["dispatch"].as_dict()
        assert d["pet"] == "wolf"
        assert d["pet_symbol"] == "dog.fill"

    def test_unknown_agent_gets_fallback_companion(self):
        u = identity_for("not_a_real_agent")
        assert u.pet == "creature"
        assert u.pet_symbol == "pawprint.fill"

    def test_label_for_includes_emoji(self):
        for aid in CORE_AGENT_IDS:
            lab = label_for(aid)
            assert IDENTITIES[aid].emoji in lab
            assert IDENTITIES[aid].display_name in lab

    def test_identity_for_unknown_is_safe(self):
        u = identity_for("not_a_real_agent")
        assert u.id == "not_a_real_agent"
        assert u.emoji


class TestStatusFromPayload:
    @pytest.mark.parametrize("agent_id", list(CORE_AGENT_IDS))
    def test_status_update_for_each_core_agent(self, agent_id):
        upd = status_from_payload(
            agent_id,
            "status",
            {"message": f"{agent_id} is compiling target 1G9V"},
        )
        assert upd.agent_id == agent_id
        assert agent_id.split("_")[0] in upd.task_summary or "1G9V" in upd.task_summary
        assert upd.status == "active"
        assert upd.event_label

    def test_uses_message_field_from_send_status(self):
        upd = status_from_payload("science", "status", {"message": "docking 1SG0"})
        assert upd.task_summary == "docking 1SG0"

    def test_approval_needed_status(self):
        upd = status_from_payload(
            "codex",
            "approval_needed",
            {"prompt": "Apply patch to hub?"},
        )
        assert upd.event_type == "approval_needed"
        assert upd.status == "waiting"


class TestAskResolve:
    @pytest.mark.parametrize("agent_id", list(CORE_AGENT_IDS))
    def test_ask_for_each_agent(self, agent_id):
        ask = ask_from_payload(
            agent_id,
            {"approval_needed": True, "prompt": f"Approve {agent_id}?"},
            interaction_id=f"i-{agent_id}",
        )
        assert ask is not None
        assert ask.agent_id == agent_id
        assert ask.status == "pending"
        assert agent_id in ask.prompt or "Approve" in ask.prompt

    def test_resolve_approve_and_deny(self):
        ask = ask_from_payload(
            "claude_code",
            {"approval_needed": True, "prompt": "Ship it?"},
            interaction_id="i-1",
        )
        assert ask is not None
        assert resolve_ask(ask, True).status == "approved"
        assert resolve_ask(ask, False).status == "denied"

    def test_no_ask_without_flag(self):
        assert ask_from_payload("science", {"text": "just status"}) is None

    def test_force_creates_ask(self):
        ask = ask_from_payload(
            "dispatch",
            {"text": "Run suite?"},
            force=True,
        )
        assert ask is not None
        assert ask.prompt
