"""Canonical detector API: dual legacy surfaces emit DeprecationWarning."""

from __future__ import annotations

import warnings

import pytest

import shannon
from shannon import ShannonCollapseDetector


def test_on_collapse_emits_deprecation_warning():
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")

        def _legacy(_event):
            pass

        ShannonCollapseDetector(window_size=4, threshold=-3.2, on_collapse=_legacy)

    deprecations = [w for w in caught if issubclass(w.category, DeprecationWarning)]
    assert deprecations, "on_collapse= must warn DeprecationWarning"
    assert any("on_collapse" in str(w.message) for w in deprecations)
    assert any("callback" in str(w.message) for w in deprecations)


def test_callback_does_not_warn():
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")

        def _cb(_result):
            pass

        ShannonCollapseDetector(window_size=4, threshold=-3.2, callback=_cb)

    deprecations = [
        w
        for w in caught
        if issubclass(w.category, DeprecationWarning)
        and "on_collapse" in str(w.message)
    ]
    assert not deprecations


@pytest.mark.skipif(not shannon._HAS_CORE, reason="C++ core not built")
def test_sliding_window_entropy_import_emits_deprecation():
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        # Force attribute lookup through package __getattr__.
        cls = getattr(shannon, "SlidingWindowEntropy")
        assert cls is not None

    deprecations = [w for w in caught if issubclass(w.category, DeprecationWarning)]
    assert deprecations, "SlidingWindowEntropy must warn DeprecationWarning"
    assert any("SlidingWindowEntropy" in str(w.message) for w in deprecations)
    assert any("ShannonCollapseDetector" in str(w.message) for w in deprecations)


def test_gate_argparse_description_is_shannon_not_flexaid():
    """Live hub CLI must not advertise FlexAIDdS (AC3 FlexAID scrub)."""
    from pathlib import Path

    text = Path(__file__).resolve().parents[2] / "hub" / "shannon_gate.py"
    src = text.read_text(encoding="utf-8")
    assert 'description="FlexAIDdS Shannon Gate' not in src
    assert "FlexAIDdS Shannon Gate" not in src
    # Shannon CLI product face (headless gate daemon).
    assert "Shannon CLI" in src
    assert "Shannon Gate" in src
