#!/usr/bin/env python3
"""
pet_atlas.py — pure Codex v2 atlas frame selection (no image I/O).

Grid constants match hatch-pet / Codex interop:
  8 columns × 11 rows, cell 192×208, standard motion rows 0–8.

Selecting a frame never loads art — callers pass motion + time and get
column/row/rect indices suitable for cropping a spritesheet.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping

# Public interop layout (Codex-compatible v2).
COLUMNS = 8
STANDARD_ROWS = 9
EXTENDED_ROWS = 11
CELL_W = 192
CELL_H = 208
ATLAS_W = COLUMNS * CELL_W
STANDARD_H = STANDARD_ROWS * CELL_H  # 1872
EXTENDED_H = EXTENDED_ROWS * CELL_H  # 2288

DEFAULT_FPS = 8.0


@dataclass(frozen=True)
class AnimStateSpec:
    name: str
    row: int
    frames: int
    purpose: str


STANDARD_STATES: tuple[AnimStateSpec, ...] = (
    AnimStateSpec("idle", 0, 6, "calm breathing / blink baseline"),
    AnimStateSpec("running-right", 1, 8, "move toward screen-right"),
    AnimStateSpec("running-left", 2, 8, "move toward screen-left"),
    AnimStateSpec("waving", 3, 4, "greeting gesture"),
    AnimStateSpec("jumping", 4, 5, "vertical hop without floor effects"),
    AnimStateSpec("failed", 5, 8, "error / deflated reaction"),
    AnimStateSpec("waiting", 6, 6, "needs user input / approval"),
    AnimStateSpec("running", 7, 6, "busy work / processing (not foot-running)"),
    AnimStateSpec("review", 8, 6, "inspect completed output"),
)

STATE_BY_NAME: Mapping[str, AnimStateSpec] = {s.name: s for s in STANDARD_STATES}


@dataclass(frozen=True)
class AtlasFrame:
    """One cell in the spritesheet grid."""

    motion: str
    row: int
    col: int
    frame_index: int
    frames_in_row: int
    x: int
    y: int
    width: int
    height: int

    @property
    def rect(self) -> tuple[int, int, int, int]:
        """(x, y, width, height) in pixels."""
        return (self.x, self.y, self.width, self.height)


def normalize_motion(motion: str) -> str:
    """Map aliases onto STANDARD_STATES names."""
    key = (motion or "").strip().lower().replace("_", "-")
    aliases = {
        "busy": "running",
        "work": "running",
        "working": "running",
        "alert": "running",
        "focused": "running",
        "error": "failed",
        "fail": "failed",
        "blocked": "waiting",
        "needs-user": "waiting",
        "ask": "waiting",
        "happy": "waving",
        "celebrate": "waving",
        "celebrating": "waving",
        "done": "review",
        "success": "review",
        "sleepy": "idle",
        "sleeping": "idle",
        "resting": "idle",
        "wary": "failed",
        "uneasy": "failed",
    }
    key = aliases.get(key, key)
    if key not in STATE_BY_NAME:
        return "idle"
    return key


def state_spec(motion: str) -> AnimStateSpec:
    return STATE_BY_NAME[normalize_motion(motion)]


def frame_index_at(
    motion: str,
    t_seconds: float,
    *,
    fps: float = DEFAULT_FPS,
    frame_offset: int = 0,
) -> int:
    """Advance multi-frame rows by time. Single-frame rows stay at 0."""
    spec = state_spec(motion)
    if spec.frames <= 1:
        return 0
    if fps <= 0:
        return max(0, frame_offset) % spec.frames
    t = max(0.0, float(t_seconds))
    idx = int(t * fps) + max(0, frame_offset)
    return idx % spec.frames


def select_frame(
    motion: str,
    t_seconds: float = 0.0,
    *,
    fps: float = DEFAULT_FPS,
    frame_offset: int = 0,
    cell_w: int = CELL_W,
    cell_h: int = CELL_H,
) -> AtlasFrame:
    """Select the atlas cell for ``motion`` at time ``t_seconds``.

    Pure: no disk I/O. Always returns a frame inside the motion's row band
    with col in ``[0, frames)``.
    """
    name = normalize_motion(motion)
    spec = STATE_BY_NAME[name]
    col = frame_index_at(name, t_seconds, fps=fps, frame_offset=frame_offset)
    row = spec.row
    return AtlasFrame(
        motion=name,
        row=row,
        col=col,
        frame_index=col,
        frames_in_row=spec.frames,
        x=col * cell_w,
        y=row * cell_h,
        width=cell_w,
        height=cell_h,
    )


def frames_advance(
    motion: str,
    t0: float,
    t1: float,
    *,
    fps: float = DEFAULT_FPS,
) -> bool:
    """True when the selected frame index advances between t0 and t1."""
    a = select_frame(motion, t0, fps=fps).frame_index
    b = select_frame(motion, t1, fps=fps).frame_index
    return a != b
