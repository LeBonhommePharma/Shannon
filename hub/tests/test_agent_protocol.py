from unittest.mock import MagicMock, patch

import pytest

import agent_protocol as ap


class TestAgentClientConstruction:
    def test_valid_agent_socket_mode(self):
        client = ap.AgentClient("science", "task_1")
        assert client.agent_id == "science"
        assert client.task_id == "task_1"
        assert client.mode == "socket"

    def test_valid_agent_http_mode(self):
        client = ap.AgentClient("codex", "task_1", mode="http")
        assert client.mode == "http"
        assert client.http_url == ap.DEFAULT_HTTP_URL

    def test_unknown_agent_raises(self):
        with pytest.raises(ValueError):
            ap.AgentClient("mallory", "task_1")

    def test_invalid_mode_raises(self):
        with pytest.raises(ValueError):
            ap.AgentClient("science", "task_1", mode="carrier_pigeon")

    def test_http_url_trailing_slash_stripped(self):
        client = ap.AgentClient("codex", "t1", mode="http", http_url="http://x.test:1234/")
        assert client.http_url == "http://x.test:1234"

    def test_local_client_helper_raises_when_gate_not_running(self):
        # local_client() eagerly connects; with no Shannon Gate socket present
        # this should surface a clear ConnectionError rather than hang.
        with pytest.raises(ConnectionError):
            ap.local_client("dispatch", "t1")

    def test_cloud_client_helper(self):
        client = ap.cloud_client("grok_build", "t1", http_url="http://x.test")
        assert client.agent_id == "grok_build"
        assert client.mode == "http"


class TestTokenAndPayloadEntropy:
    def test_token_entropy_empty(self):
        assert ap._token_entropy("") == 0.0

    def test_token_entropy_positive_for_diverse_text(self):
        assert ap._token_entropy("alpha beta gamma delta") > 0.0

    def test_payload_entropy_uses_known_text_keys(self):
        H = ap._payload_entropy({"text": "alpha beta gamma delta"})
        assert H > 0.0

    def test_payload_entropy_falls_back_to_values(self):
        H = ap._payload_entropy({"cf_value": -3.2, "rmsd": 1.1})
        assert H >= 0.0


class TestCredentialManagerCredentialCheck:
    def test_local_agent_always_true(self):
        assert ap.CredentialManager.credential_check("science") is True

    def test_cloud_agent_missing_token_raises(self):
        with patch.object(ap.CredentialManager, "load", return_value=None):
            with pytest.raises(ap.AuthError):
                ap.CredentialManager.credential_check("grok_build")

    def test_cloud_agent_valid_token_pings_endpoint(self):
        fake_resp = MagicMock(status_code=200)
        with patch.object(ap.CredentialManager, "load", return_value="tok"), \
             patch.object(ap, "HAS_REQUESTS", True), \
             patch.object(ap, "_requests", MagicMock(get=MagicMock(return_value=fake_resp)), create=True):
            assert ap.CredentialManager.credential_check("grok_build") is True

    def test_cloud_agent_rejected_token_raises(self):
        fake_resp = MagicMock(status_code=401)
        with patch.object(ap.CredentialManager, "load", return_value="tok"), \
             patch.object(ap, "HAS_REQUESTS", True), \
             patch.object(ap, "_requests", MagicMock(get=MagicMock(return_value=fake_resp)), create=True):
            with pytest.raises(ap.AuthError):
                ap.CredentialManager.credential_check("grok_build")

    def test_credential_manager_store_calls_security_cli(self):
        with patch("agent_protocol.subprocess.run", return_value=MagicMock(returncode=0)) as run:
            assert ap.CredentialManager.store("grok_build", "tok") is True
            args = run.call_args[0][0]
            assert args[0] == "security"
            assert "add-generic-password" in args

    def test_credential_manager_load_from_keychain(self):
        result = MagicMock(returncode=0, stdout="secret\n")
        with patch("agent_protocol.subprocess.run", return_value=result):
            assert ap.CredentialManager.load("grok_build") == "secret"
