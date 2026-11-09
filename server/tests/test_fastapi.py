from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("LITEROUTER_PRIMARY_BASE_URL", "https://primary.example/v1")
os.environ.setdefault("LITEROUTER_PRIMARY_API_KEY", "primary-secret")
os.environ.setdefault("LITEROUTER_PRIMARY_MODEL", "primary-model")
os.environ.setdefault("LITEROUTER_SECONDARY_BASE_URL", "https://secondary.example/v1")
os.environ.setdefault("LITEROUTER_SECONDARY_API_KEY", "secondary-secret")
os.environ.setdefault("LITEROUTER_SECONDARY_MODEL", "secondary-model")

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app as fastapi_app

client = TestClient(fastapi_app.app)


def test_health_exposes_configuration_not_secrets() -> None:
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["primary_configured"] is True
    assert body["secondary_configured"] is True
    assert "primary-secret" not in response.text
    assert "secondary-secret" not in response.text


def test_chat_has_no_app_bearer_token_requirement(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(fastapi_app, "_request_upstream", AsyncMock(return_value="Direct FastAPI answer"))
    response = client.post("/v1/chat/completions", json={"messages": [{"role": "user", "content": "Hi"}]})
    assert response.status_code == 200
    assert response.json()["content"] == "Direct FastAPI answer"


def test_chat_primary_success(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(fastapi_app, "_request_upstream", AsyncMock(return_value="Primary answer"))
    response = client.post("/v1/chat/completions", json={"messages": [{"role": "user", "content": "Hi"}]})
    assert response.status_code == 200
    assert response.json()["content"] == "Primary answer"
    assert response.json()["server"] == "primary"
    assert response.json()["fallback_used"] is False


def test_chat_falls_back_to_secondary(monkeypatch: pytest.MonkeyPatch) -> None:
    async def route(upstream, payload):
        if upstream.name == "primary":
            raise ConnectionError("primary unavailable")
        return "Secondary answer"
    monkeypatch.setattr(fastapi_app, "_request_upstream", route)
    response = client.post("/v1/chat/completions", json={"messages": [{"role": "user", "content": "Hi"}]})
    assert response.status_code == 200
    assert response.json()["content"] == "Secondary answer"
    assert response.json()["server"] == "secondary"
    assert response.json()["fallback_used"] is True


def test_chat_validates_messages() -> None:
    response = client.post("/v1/chat/completions", json={"messages": [{"role": "tool", "content": "bad"}]})
    assert response.status_code == 422


def test_primary_auth_failure_does_not_hide_bad_credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = []
    async def route(upstream, payload):
        calls.append(upstream.name)
        raise PermissionError("bad primary key")
    monkeypatch.setattr(fastapi_app, "_request_upstream", route)
    response = client.post("/v1/chat/completions", json={"messages": [{"role": "user", "content": "Hi"}]})
    assert response.status_code == 502
    assert calls == ["primary"]


def test_both_servers_down_returns_503(monkeypatch: pytest.MonkeyPatch) -> None:
    async def route(upstream, payload):
        raise ConnectionError("offline")
    monkeypatch.setattr(fastapi_app, "_request_upstream", route)
    response = client.post("/v1/chat/completions", json={"messages": [{"role": "user", "content": "Hi"}]})
    assert response.status_code == 503


class _FakeUpstreamResponse:
    """Async response context manager for deterministic upstream tests."""

    def __init__(self, body: bytes, status_code: int = 200) -> None:
        self.body = body
        self.status_code = status_code
        self.is_success = 200 <= status_code < 300

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        return None

    async def aiter_bytes(self):
        yield self.body


class _FakeAsyncClient:
    """Minimal AsyncClient replacement that captures the outbound request."""

    def __init__(self, **kwargs) -> None:
        self.options = kwargs
        self.request = None

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, traceback) -> None:
        return None

    def stream(self, method, url, *, headers, json):
        self.request = {
            "method": method,
            "url": url,
            "headers": headers,
            "json": json,
        }
        return _FakeUpstreamResponse(
            body=b'{"choices":[{"message":{"content":"Parsed answer"}}]}'
        )


def test_request_upstream_parses_successful_json_response(monkeypatch: pytest.MonkeyPatch) -> None:
    fake_client = _FakeAsyncClient()
    monkeypatch.setattr(fastapi_app.httpx, "AsyncClient", lambda **kwargs: fake_client)
    payload = {"messages": [{"role": "user", "content": "Hi"}], "stream": False}

    content = asyncio.run(fastapi_app._request_upstream(fastapi_app.PRIMARY, payload))

    assert content == "Parsed answer"
    assert fake_client.request is not None
    assert fake_client.request["method"] == "POST"
    assert fake_client.request["url"] == "https://primary.example/v1/chat/completions"
    assert fake_client.request["json"]["model"] == "primary-model"
    assert fake_client.request["headers"]["Authorization"] == "Bearer primary-secret"


def test_request_upstream_rejects_malformed_json_response(monkeypatch: pytest.MonkeyPatch) -> None:
    class MalformedClient(_FakeAsyncClient):
        def stream(self, method, url, *, headers, json):
            return _FakeUpstreamResponse(body=b"not-json")

    monkeypatch.setattr(fastapi_app.httpx, "AsyncClient", lambda **kwargs: MalformedClient())

    with pytest.raises(RuntimeError, match="primary returned an invalid chat response"):
        asyncio.run(fastapi_app._request_upstream(fastapi_app.PRIMARY, {"messages": []}))
