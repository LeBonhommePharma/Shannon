"""Tests for credentials.py — all Keychain access is mocked, never real."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import credentials  # noqa: E402
from credentials import (
    AuthError,
    KeychainStore,
    KeychainUnavailableError,
    _ERR_SEC_INTERACTION_NOT_ALLOWED,
    _redact,
    check_cloud_agent,
    credential_exists,
)


def _cp(returncode=0, stdout=b"", stderr=b""):
    return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr=stderr)


class TestKeychainStore:
    @patch("credentials.subprocess.run")
    def test_store_success(self, mock_run):
        mock_run.return_value = _cp(returncode=0)
        KeychainStore.store("grok_build", "secret-token")
        assert mock_run.called
        args = mock_run.call_args[0][0]
        assert "add-generic-password" in args
        assert "secret-token" in args

    @patch("credentials.subprocess.run")
    def test_store_duplicate_returncode_ok(self, mock_run):
        mock_run.return_value = _cp(returncode=45)
        KeychainStore.store("grok_build", "secret-token")  # should not raise

    @patch("credentials.subprocess.run")
    def test_store_failure_raises_runtime_error(self, mock_run):
        mock_run.return_value = _cp(returncode=1, stderr=b"boom")
        try:
            KeychainStore.store("grok_build", "secret-token")
            assert False, "expected RuntimeError"
        except RuntimeError:
            pass

    @patch("credentials.subprocess.run")
    def test_load_found(self, mock_run):
        mock_run.return_value = _cp(returncode=0, stdout=b"the-token\n")
        val = KeychainStore.load("grok_build")
        assert val == "the-token"

    @patch("credentials.subprocess.run")
    def test_load_not_found_no_env_fallback(self, mock_run, monkeypatch):
        mock_run.return_value = _cp(returncode=1, stdout=b"")
        monkeypatch.delenv("GROK_API_KEY", raising=False)
        monkeypatch.delenv("XAI_API_KEY", raising=False)
        val = KeychainStore.load("grok_build")
        assert val is None

    @patch("credentials.subprocess.run")
    def test_load_env_fallback(self, mock_run, monkeypatch):
        mock_run.return_value = _cp(returncode=1, stdout=b"")
        monkeypatch.setenv("GROK_API_KEY", "env-token")
        val = KeychainStore.load("grok_build")
        assert val == "env-token"

    @patch("credentials.subprocess.run")
    def test_delete(self, mock_run):
        mock_run.return_value = _cp(returncode=0)
        assert KeychainStore.delete("grok_build") is True

    @patch("credentials.subprocess.run")
    def test_has_credential_true(self, mock_run):
        mock_run.return_value = _cp(returncode=0, stdout=b"tok")
        assert KeychainStore.has_credential("grok_build") is True


class TestRetryBackoff:
    @patch("credentials.time.sleep")
    @patch("credentials.subprocess.run")
    def test_retries_on_interaction_not_allowed(self, mock_run, mock_sleep):
        locked = _cp(returncode=1, stderr=f"security: SecKeychainItemCopyContent: ({_ERR_SEC_INTERACTION_NOT_ALLOWED})".encode())
        mock_run.return_value = locked
        try:
            KeychainStore.load.__wrapped__ if hasattr(KeychainStore.load, "__wrapped__") else None
        except Exception:
            pass
        try:
            credentials._run_security_with_retry(
                ["security", "find-generic-password"], agent_id="grok_build", account="grok_build.token", timeout=1
            )
            assert False, "expected KeychainUnavailableError"
        except KeychainUnavailableError:
            pass
        # 1 initial + 3 retries = 4 calls total
        assert mock_run.call_count == 4
        assert mock_sleep.call_count == 3

    @patch("credentials.subprocess.run")
    def test_non_locked_error_returns_immediately(self, mock_run):
        mock_run.return_value = _cp(returncode=1, stderr=b"some other error")
        result = credentials._run_security_with_retry(
            ["security", "find-generic-password"], agent_id="grok_build", account="grok_build.token", timeout=1
        )
        assert result.returncode == 1
        assert mock_run.call_count == 1


class TestCredentialExists:
    @patch("credentials._run_security_with_retry")
    def test_exists_true(self, mock_retry):
        mock_retry.return_value = _cp(returncode=0)
        assert credential_exists("Shannon.AgentHub", "grok_build.token") is True

    @patch("credentials._run_security_with_retry")
    def test_exists_false(self, mock_retry):
        mock_retry.return_value = _cp(returncode=1)
        assert credential_exists("Shannon.AgentHub", "grok_build.token") is False


class TestRedact:
    def test_redact_masks_value(self):
        msg = _redact("grok_build", "grok_build.token", "supersecrettoken1234")
        assert "supersecrettoken1234" not in msg
        assert "1234" in msg
        assert "grok_build" in msg

    def test_redact_empty_value(self):
        msg = _redact("grok_build", "grok_build.token", None)
        assert "<empty>" in msg


class TestCheckCloudAgent:
    def test_local_agent_always_true(self):
        assert check_cloud_agent("dataset_runner") is True

    @patch("credentials.KeychainStore.load", return_value=None)
    def test_missing_token_raises_autherror(self, mock_load):
        try:
            check_cloud_agent("grok_build")
            assert False
        except AuthError:
            pass

    @patch("credentials.HAS_REQUESTS", True)
    @patch("credentials._requests")
    @patch("credentials.KeychainStore.load", return_value="tok")
    def test_valid_token_200(self, mock_load, mock_requests):
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_requests.get.return_value = mock_resp
        assert check_cloud_agent("grok_build") is True

    @patch("credentials.HAS_REQUESTS", True)
    @patch("credentials._requests")
    @patch("credentials.KeychainStore.load", return_value="tok")
    def test_rejected_token_401(self, mock_load, mock_requests):
        mock_resp = MagicMock()
        mock_resp.status_code = 401
        mock_requests.get.return_value = mock_resp
        try:
            check_cloud_agent("grok_build")
            assert False
        except AuthError:
            pass
