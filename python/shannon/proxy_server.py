"""Minimal OpenAI-compatible Shannon proxy (P2.5 MVP).

Endpoints:
  GET  /health              → {"status": "ok", ...}
  POST /v1/chat/completions → mock echo when SHANNON_PROXY_MOCK=1 (default for
                              local/dev), else forward to OPENAI_BASE_URL

Mock mode returns a normal chat.completion JSON and does **not** invent
logprobs / entropy-collapse fields — those come only from a real model or
the Shannon detector path.

Pure helpers (no network) for unit tests:
  build_mock_completion(messages) -> dict
  handle_proxy_request(method, path, body, mock=...) -> (status, dict)
"""

from __future__ import annotations

import json
import os
import time
import uuid
from typing import Any, Optional
from urllib import error as urlerror
from urllib import request as urlrequest

__all__ = [
    "build_mock_completion",
    "forward_chat_completions",
    "handle_chat_completions_body",
    "handle_proxy_request",
    "health_payload",
    "main",
]


def health_payload() -> dict[str, str]:
    return {"status": "ok", "service": "shannon-proxy"}


def build_mock_completion(
    messages: list[dict[str, Any]] | None,
    model: str = "shannon-mock",
    *,
    request_id: str | None = None,
) -> dict[str, Any]:
    """Pure mock OpenAI chat.completion — no logprobs, no collapse claims.

    Echoes the last user message content (string or first text part). Does not
    invent measurement fields that would look like Shannon detector output.
    """
    last = ""
    for m in reversed(messages or []):
        if not isinstance(m, dict):
            continue
        if m.get("role") != "user":
            continue
        c = m.get("content")
        if isinstance(c, str):
            last = c
        elif isinstance(c, list):
            for part in c:
                if isinstance(part, dict) and part.get("type") == "text":
                    last = str(part.get("text") or "")
                    break
        break
    text = last if last else "ok"
    return {
        "id": request_id or f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "total_tokens": 0,
        },
        # Explicitly no logprobs — clients must treat measurement as absent.
    }


def _mock_enabled(explicit: bool | None = None) -> bool:
    if explicit is not None:
        return explicit
    return os.environ.get("SHANNON_PROXY_MOCK", "1").strip().lower() not in (
        "0",
        "false",
        "no",
        "off",
    )


def handle_chat_completions_body(
    body: dict[str, Any],
    *,
    mock: bool | None = None,
    base_url: str | None = None,
    api_key: str | None = None,
) -> tuple[int, dict[str, Any]]:
    """Request path for POST /v1/chat/completions (pure when mock=True)."""
    messages = body.get("messages") or []
    if not isinstance(messages, list):
        messages = []
    model = str(body.get("model") or "shannon-mock")
    if _mock_enabled(mock):
        return 200, build_mock_completion(list(messages), model=model)
    status, result = forward_chat_completions(
        body, base_url=base_url, api_key=api_key
    )
    if isinstance(result, dict):
        return status, result
    return status, {"error": {"message": str(result), "type": "upstream_error"}}


def forward_chat_completions(
    body: dict[str, Any] | bytes | str,
    *,
    base_url: str | None = None,
    api_key: str | None = None,
    timeout: float = 60.0,
) -> tuple[int, dict[str, Any] | str]:
    """POST body to ``{base_url}/v1/chat/completions``."""
    base = (
        base_url
        or os.environ.get("OPENAI_BASE_URL")
        or "https://api.openai.com"
    ).rstrip("/")
    url = f"{base}/v1/chat/completions"
    if isinstance(body, (dict, list)):
        raw = json.dumps(body).encode("utf-8")
    elif isinstance(body, str):
        raw = body.encode("utf-8")
    else:
        raw = body

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    key = api_key if api_key is not None else os.environ.get("OPENAI_API_KEY", "")
    if key:
        headers["Authorization"] = f"Bearer {key}"

    req = urlrequest.Request(url, data=raw, headers=headers, method="POST")
    try:
        with urlrequest.urlopen(req, timeout=timeout) as resp:
            data = resp.read().decode("utf-8", "replace")
            try:
                return int(resp.status), json.loads(data)
            except json.JSONDecodeError:
                return int(resp.status), data
    except urlerror.HTTPError as e:
        err_body = e.read().decode("utf-8", "replace") if e.fp else str(e)
        try:
            return int(e.code), json.loads(err_body)
        except json.JSONDecodeError:
            return int(e.code), err_body
    except urlerror.URLError as e:
        return 502, {"error": {"message": str(e.reason), "type": "proxy_error"}}


def handle_proxy_request(
    method: str,
    path: str,
    body: bytes | None = None,
    *,
    mock: bool | None = None,
    base_url: str | None = None,
    api_key: str | None = None,
) -> tuple[int, dict[str, Any]]:
    """Pure request dispatcher used by the HTTP handler and unit tests."""
    path_only = path.split("?", 1)[0].rstrip("/") or "/"
    method_u = method.upper()

    if method_u == "GET" and path_only in ("/health", "/v1/health"):
        return 200, health_payload()

    if method_u == "POST" and path_only in (
        "/v1/chat/completions",
        "/chat/completions",
    ):
        try:
            payload = json.loads(body or b"{}")
        except json.JSONDecodeError:
            return 400, {
                "error": {
                    "message": "invalid JSON",
                    "type": "invalid_request_error",
                }
            }
        if not isinstance(payload, dict):
            return 400, {
                "error": {
                    "message": "body must be a JSON object",
                    "type": "invalid_request_error",
                }
            }
        return handle_chat_completions_body(
            payload, mock=mock, base_url=base_url, api_key=api_key
        )

    return 404, {
        "error": {
            "message": f"not found: {path_only}",
            "type": "not_found",
        }
    }


def main(argv: Optional[list[str]] = None) -> None:
    """Optional stdlib server for manual runs."""
    import argparse
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    p = argparse.ArgumentParser(description="Shannon OpenAI-compatible proxy (MVP)")
    p.add_argument("--host", default=os.environ.get("SHANNON_PROXY_HOST", "127.0.0.1"))
    p.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("SHANNON_PROXY_PORT", "8787")),
    )
    p.add_argument(
        "--mock",
        action="store_true",
        default=_mock_enabled(),
        help="Return mock chat completions (no upstream call)",
    )
    p.add_argument(
        "--no-mock",
        action="store_true",
        help="Forward to OPENAI_BASE_URL instead of mocking",
    )
    args = p.parse_args(argv)
    mock = False if args.no_mock else args.mock

    class H(BaseHTTPRequestHandler):
        def _json(self, code: int, obj: dict) -> None:
            data = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:  # noqa: N802
            code, obj = handle_proxy_request("GET", self.path, mock=mock)
            self._json(code, obj)

        def do_POST(self) -> None:  # noqa: N802
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b"{}"
            code, obj = handle_proxy_request(
                "POST", self.path, raw, mock=mock
            )
            self._json(code, obj)

        def log_message(self, fmt: str, *args: Any) -> None:
            return

    httpd = ThreadingHTTPServer((args.host, args.port), H)
    print(f"shannon proxy on http://{args.host}:{args.port} mock={mock}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
