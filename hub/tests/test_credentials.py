import sys
from unittest.mock import MagicMock, patch

import pytest

import credentials as creds

pytestmark = pytest.mark.skipif(
    sys.platform != "darwin",
    reason="credentials.py wraps the macOS Security framework `security` CLI",
)


def _completed(returncode=0, stdout="", stderr=""):
    return MagicMock(returncode=returncode, stdout=stdout, stderr=stderr.encode()
                      if isinstance(stderr, str) else stderr)


class TestKeychainStore:
    def test_store_calls_security_add_generic_password(self):
        with patch("credentials.subprocess.run", return_value=_completed(0)) as run:
            creds.KeychainStore.store("grok_build", "secret-token")
            args = run.call_args[0][0]
            assert args[0] == "security"
            assert "add-generic-password" in args
            assert "grok_build.token" in args
            assert "secret-token" in args

    def test_store_raises_on_unexpected_failure(self):
        with patch("credentials.subprocess.run", return_value=_completed(1, stderr="boom")):
            with pytest.raises(RuntimeError):
                creds.KeychainStore.store("grok_build", "x")

    def test_store_treats_duplicate_code_as_success(self):
        with patch("credentials.subprocess.run", return_value=_completed(45)):
            creds.KeychainStore.store("grok_build", "x")  # should not raise

    def test_load_returns_stdout_on_success(self):
        with patch("credentials.subprocess.run",
                    return_value=_completed(0, stdout="my-secret-token\n")):
            assert creds.KeychainStore.load("grok_build") == "my-secret-token"

    def test_load_falls_back_to_env_var(self, monkeypatch):
        monkeypatch.setenv("GROK_API_KEY", "env-token")
        with patch("credentials.subprocess.run", return_value=_completed(1)):
            assert creds.KeychainStore.load("grok_build") == "env-token"

    def test_load_returns_none_when_nothing_found(self, monkeypatch):
        monkeypatch.delenv("GROK_API_KEY", raising=False)
        monkeypatch.delenv("XAI_API_KEY", raising=False)
        with patch("credentials.subprocess.run", return_value=_completed(1)):
            assert creds.KeychainStore.load("grok_build") is None

    def test_delete_returns_true_on_success(self):
        with patch("credentials.subprocess.run", return_value=_completed(0)):
            assert creds.KeychainStore.delete("grok_build") is True

    def test_delete_returns_false_when_not_found(self):
        with patch("credentials.subprocess.run", return_value=_completed(44)):
            assert creds.KeychainStore.delete("grok_build") is False

    def test_has_credential_true_when_loaded(self):
        with patch("credentials.subprocess.run", return_value=_completed(0, stdout="tok\n")):
            assert creds.KeychainStore.has_credential("grok_build") is True


class TestCheckCloudAgent:
    def test_local_agent_always_passes(self):
        assert creds.check_cloud_agent("dataset_runner") is True

    def test_missing_token_raises_autherror(self):
        with patch.object(creds.KeychainStore, "load", return_value=None):
            with pytest.raises(creds.AuthError):
                creds.check_cloud_agent("grok_build")

    def test_valid_token_and_200_response_passes(self):
        fake_resp = MagicMock(status_code=200)
        with patch.object(creds.KeychainStore, "load", return_value="tok"), \
             patch.object(creds, "HAS_REQUESTS", True), \
             patch.object(creds, "_requests", MagicMock(get=MagicMock(return_value=fake_resp)), create=True):
            assert creds.check_cloud_agent("grok_build") is True

    def test_401_response_raises_autherror(self):
        fake_resp = MagicMock(status_code=401)
        with patch.object(creds.KeychainStore, "load", return_value="tok"), \
             patch.object(creds, "HAS_REQUESTS", True), \
             patch.object(creds, "_requests", MagicMock(get=MagicMock(return_value=fake_resp)), create=True):
            with pytest.raises(creds.AuthError):
                creds.check_cloud_agent("grok_build")
