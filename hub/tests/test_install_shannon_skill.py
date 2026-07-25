"""Tests for skills/shannon/scripts/install_skill.py (pure filesystem)."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
INSTALL = REPO / "skills" / "shannon" / "scripts" / "install_skill.py"


def _load_install():
    spec = importlib.util.spec_from_file_location("install_shannon_skill", INSTALL)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules["install_shannon_skill"] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def install_mod():
    return _load_install()


class TestInstallSkill:
    def test_source_has_skill_md(self):
        assert (REPO / "skills" / "shannon" / "SKILL.md").is_file()

    def test_dry_run_repo_local(self, install_mod, capsys, tmp_path):
        # dry-run against real repo should report destinations (or already-present)
        rc = install_mod.main(["--dry-run", "--home", str(tmp_path)])
        assert rc == 0
        out = capsys.readouterr().out
        assert "shannon" in out
        assert "dry-run" in out or "skip self" in out or "already present" in out

    def test_copy_into_fake_home_hosts(self, install_mod, tmp_path):
        # Pretend user hosts exist
        (tmp_path / ".claude" / "skills").mkdir(parents=True)
        (tmp_path / ".codex" / "skills").mkdir(parents=True)
        (tmp_path / ".grok" / "skills").mkdir(parents=True)
        (tmp_path / ".config" / "opencode").mkdir(parents=True)

        rc = install_mod.main(["--home", str(tmp_path)])
        assert rc == 0
        assert (tmp_path / ".claude" / "skills" / "shannon" / "SKILL.md").is_file()
        assert (tmp_path / ".codex" / "skills" / "shannon" / "SKILL.md").is_file()
        assert (tmp_path / ".grok" / "skills" / "shannon" / "SKILL.md").is_file()
        assert (
            tmp_path / ".config" / "opencode" / "skills" / "shannon" / "SKILL.md"
        ).is_file()

    def test_symlink_mode(self, install_mod, tmp_path):
        (tmp_path / ".claude" / "skills").mkdir(parents=True)
        rc = install_mod.main(["--symlink", "--home", str(tmp_path)])
        assert rc == 0
        dest = tmp_path / ".claude" / "skills" / "shannon"
        assert dest.is_symlink() or (dest / "SKILL.md").is_file()
