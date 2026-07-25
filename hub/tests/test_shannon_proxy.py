"""P2.5: OpenAI-compatible proxy MVP — pure mock completion shape tests."""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Repo-root python/ on path so `shannon.proxy_server` resolves without install.
_ROOT = Path(__file__).resolve().parents[2]
_PY = _ROOT / "python"
if str(_PY) not in sys.path:
    sys.path.insert(0, str(_PY))

# Prefer the source tree module over any installed egg that may lag.
import importlib

import shannon.proxy_server as _proxy_mod

importlib.reload(_proxy_mod)

from shannon.proxy_server import (  # noqa: E402
    build_mock_completion,
    handle_chat_completions_body,
    handle_proxy_request,
    health_payload,
)


class TestBuildMockCompletion:
    def test_shape_and_echo(self):
        messages = [
            {"role": "system", "content": "you are helpful"},
            {"role": "user", "content": "hello shannon"},
        ]
        out = build_mock_completion(
            messages, model="shannon-mock", request_id="chatcmpl-test"
        )
        assert out["object"] == "chat.completion"
        assert out["id"] == "chatcmpl-test"
        assert out["model"] == "shannon-mock"
        assert isinstance(out["created"], int)
        assert len(out["choices"]) == 1
        choice = out["choices"][0]
        assert choice["message"]["role"] == "assistant"
        assert choice["message"]["content"] == "hello shannon"
        assert choice["finish_reason"] == "stop"
        assert "prompt_tokens" in out["usage"]
        # Must NOT invent logprobs / collapse fields.
        assert "logprobs" not in choice
        assert "entropy" not in out
        assert "collapse" not in json.dumps(out).lower()

    def test_empty_messages_placeholder(self):
        out = build_mock_completion([])
        assert out["choices"][0]["message"]["content"] == "ok"

    def test_multimodal_user_content(self):
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "describe this"},
                    {"type": "image_url", "image_url": {"url": "x"}},
                ],
            }
        ]
        out = build_mock_completion(messages)
        assert out["choices"][0]["message"]["content"] == "describe this"


class TestHandleProxyRequest:
    def test_health(self):
        status, body = handle_proxy_request("GET", "/health", mock=True)
        assert status == 200
        assert body["status"] == "ok"

    def test_mock_chat_completions(self):
        payload = json.dumps(
            {
                "model": "gpt-test",
                "messages": [{"role": "user", "content": "ping"}],
            }
        ).encode()
        status, body = handle_proxy_request(
            "POST", "/v1/chat/completions", payload, mock=True
        )
        assert status == 200
        assert body["object"] == "chat.completion"
        assert body["choices"][0]["message"]["content"] == "ping"
        assert body["model"] == "gpt-test"

    def test_handle_chat_completions_body_mock(self):
        code, obj = handle_chat_completions_body(
            {"messages": [{"role": "user", "content": "hi"}], "model": "m"},
            mock=True,
        )
        assert code == 200
        assert obj["choices"][0]["message"]["content"] == "hi"

    def test_invalid_json(self):
        status, body = handle_proxy_request(
            "POST", "/v1/chat/completions", b"{not-json", mock=True
        )
        assert status == 400
        assert "error" in body

    def test_not_found(self):
        status, body = handle_proxy_request("GET", "/nope", mock=True)
        assert status == 404


class TestHealthPayload:
    def test_status_ok(self):
        assert health_payload()["status"] == "ok"
