"""P2.5 OpenAI-compatible proxy pure path."""

from __future__ import annotations

import os

from shannon.proxy_server import (
    build_mock_completion,
    handle_chat_completions_body,
    health_payload,
)


def test_mock_completion_shape():
    c = build_mock_completion([{"role": "user", "content": "hello entropy"}])
    assert c["object"] == "chat.completion"
    assert c["choices"][0]["message"]["role"] == "assistant"
    assert "hello entropy" in c["choices"][0]["message"]["content"]
    # Must not invent logprobs / collapse claims
    assert "logprobs" not in c["choices"][0]


def test_handle_chat_completions_mock():
    os.environ["SHANNON_PROXY_MOCK"] = "1"
    code, body = handle_chat_completions_body(
        {"model": "gpt-test", "messages": [{"role": "user", "content": "ping"}]}
    )
    assert code == 200
    assert body["choices"][0]["message"]["content"]


def test_health():
    assert health_payload()["status"] == "ok"
