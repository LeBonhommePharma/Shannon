"""Tests for agent_protocol.py hardening: require_credentials, token rotation, rate limiting."""
from __future__ import annotations

import sys
import time
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import agent_protocol as ap  # noqa: E402
from agent_protocol import (
    AuthError,
    CredentialManager,
    RateLimiter,
    RateLimitExceeded,
    _token_entropy,
    _payload_entropy,
)


class TestCredentialManager:
    @patch("agent_protocol.subprocess.run")
    def test_load_from_keychain(self, mock_run):
        mock_run.return_value.returncode = 0
        mock_run.return_value.stdout = "kc-token\n"
        val = CredentialManager.load("grok_build")
        assert val == "kc-token"

    def test_local_agent_always_passes_check(self):
        assert CredentialManager.credential_check("dataset_runner") is True

    @patch("agent_protocol.CredentialManager.load", return_value=None)
    def test_missing_cloud_credential_raises(self, mock_load):
        try:
            CredentialManager.credential_check("grok_build")
            assert False
        except AuthError:
            pass

    def test_rotate_not_needed_when_far_from_expiry(self):
        CredentialManager.rotate_if_needed("grok_build", time.time() + 3600)  # no raise

    def test_rotate_raises_when_near_expiry(self):
        try:
            CredentialManager.rotate_if_needed("grok_build", time.time() + 60, margin_s=300)
            assert False
        except AuthError:
            pass

    def test_rotate_noop_for_local_agent(self):
        CredentialManager.rotate_if_needed("dataset_runner", time.time())  # no raise, no expiry check


class TestRateLimiter:
    def test_allows_up_to_limit(self):
        rl = RateLimiter(max_per_minute=3)
        rl.check("agent_a")
        rl.check("agent_a")
        rl.check("agent_a")  # 3rd call ok

    def test_blocks_over_limit(self):
        rl = RateLimiter(max_per_minute=2)
        rl.check("agent_a")
        rl.check("agent_a")
        try:
            rl.check("agent_a")
            assert False, "expected RateLimitExceeded"
        except RateLimitExceeded as exc:
            assert exc.status_code == 429
            assert "Retry-After" in exc.headers

    def test_independent_per_agent(self):
        rl = RateLimiter(max_per_minute=1)
        rl.check("agent_a")
        rl.check("agent_b")  # different agent, should not raise

    def test_window_resets(self):
        rl = RateLimiter(max_per_minute=1)
        rl.check("agent_a")
        # simulate time passing beyond window by manipulating internal events
        rl._events["agent_a"] = [time.time() - 61]
        rl.check("agent_a")  # should be allowed again


class TestRequireCredentialsDecorator:
    def test_decorator_blocks_on_missing_credential(self):
        class FakeClient:
            agent_id = "grok_build"
            task_id = "t1"

            @ap.require_credentials
            def do_send(self):
                return "sent"

        with patch("agent_protocol.CredentialManager.credential_check", side_effect=AuthError("grok_build", "no cred")):
            client = FakeClient()
            try:
                client.do_send()
                assert False
            except AuthError:
                pass

    def test_decorator_allows_when_credentials_ok(self):
        class FakeClient:
            agent_id = "dataset_runner"
            task_id = "t1"

            @ap.require_credentials
            def do_send(self):
                return "sent"

        client = FakeClient()
        assert client.do_send() == "sent"

    def test_decorator_enforces_rate_limit(self):
        class FakeClient:
            agent_id = "local_test_rl_agent"
            task_id = "t1"

            @ap.require_credentials
            def do_send(self):
                return "sent"

        client = FakeClient()
        ap._RATE_LIMITER.max_per_minute = 2
        try:
            client.do_send()
            client.do_send()
            try:
                client.do_send()
                assert False, "expected RateLimitExceeded"
            except RateLimitExceeded:
                pass
        finally:
            ap._RATE_LIMITER.max_per_minute = 60
            ap._RATE_LIMITER._events.pop("local_test_rl_agent", None)


class TestEntropyHelpers:
    def test_token_entropy_empty(self):
        assert _token_entropy("") == 0.0

    def test_token_entropy_single_token(self):
        assert _token_entropy("hello") == 0.0

    def test_token_entropy_positive_for_varied_text(self):
        assert _token_entropy("the quick brown fox jumps over the lazy dog") > 0

    def test_payload_entropy_uses_known_keys(self):
        val = _payload_entropy({"text": "the quick brown fox jumps"})
        assert val > 0

    def test_payload_entropy_empty_payload(self):
        assert _payload_entropy({}) == 0.0
