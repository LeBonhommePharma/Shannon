"""Tests for pure Codex v2 atlas frame selection (shipped pet_atlas)."""

from __future__ import annotations

import pet_atlas as atlas


class TestGridConstants:
    def test_codex_v2_grid(self):
        assert atlas.COLUMNS == 8
        assert atlas.EXTENDED_ROWS == 11
        assert atlas.CELL_W == 192
        assert atlas.CELL_H == 208
        assert atlas.ATLAS_W == 1536
        assert atlas.EXTENDED_H == 2288

    def test_standard_states_cover_core_rows(self):
        names = {s.name for s in atlas.STANDARD_STATES}
        for required in ("idle", "running", "waiting", "failed", "review"):
            assert required in names


class TestSelectFrame:
    def test_each_core_motion_in_correct_row_band(self):
        expected_row = {
            "idle": 0,
            "running": 7,
            "waiting": 6,
            "failed": 5,
            "review": 8,
        }
        for motion, row in expected_row.items():
            fr = atlas.select_frame(motion, 0.0)
            assert fr.row == row, f"{motion}: row {fr.row} != {row}"
            assert fr.col >= 0
            assert fr.col < fr.frames_in_row
            assert fr.width == 192
            assert fr.height == 208
            assert fr.x == fr.col * 192
            assert fr.y == row * 208
            assert fr.rect == (fr.x, fr.y, 192, 208)

    def test_unknown_motion_falls_back_to_idle(self):
        fr = atlas.select_frame("not-a-real-motion", 0.0)
        assert fr.motion == "idle"
        assert fr.row == 0

    def test_aliases(self):
        assert atlas.select_frame("busy", 0).motion == "running"
        assert atlas.select_frame("blocked", 0).motion == "waiting"
        assert atlas.select_frame("happy", 0).motion == "waving"
        assert atlas.select_frame("wary", 0).motion == "failed"

    def test_multi_frame_advances_with_time(self):
        # idle has 6 frames; at fps=8, frame changes within 1s
        f0 = atlas.select_frame("idle", 0.0, fps=8.0)
        f1 = atlas.select_frame("idle", 0.2, fps=8.0)  # 1.6 → frame 1
        assert f0.frame_index == 0
        assert f1.frame_index == 1
        assert atlas.frames_advance("idle", 0.0, 0.2, fps=8.0)
        assert atlas.frames_advance("running", 0.0, 1.0, fps=8.0)
        assert atlas.frames_advance("waiting", 0.0, 1.0, fps=8.0)

    def test_frame_wraps_within_row(self):
        # idle: 6 frames; t large enough to wrap
        fr = atlas.select_frame("idle", 10.0, fps=8.0)  # 80 frames → 80 % 6
        assert 0 <= fr.frame_index < 6
        assert fr.col == fr.frame_index

    def test_waving_and_jumping_rows(self):
        assert atlas.select_frame("waving", 0).row == 3
        assert atlas.select_frame("jumping", 0).row == 4
