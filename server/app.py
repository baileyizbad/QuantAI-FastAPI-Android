from __future__ import annotations

import asyncio
import json
import os
import time
from dataclasses import dataclass
from typing import Any, Literal
from urllib.parse import urlsplit

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator

import httpx

APP_NAME = "QuantAI FastAPI"

@dataclass(frozen=True)
class Upstream:
    name: str
    base_url: str
    api_key: str
    model: str

    @property
    def configured(self) -> bool:
        return bool(self.base_url and self.api_key and self.model)


def _upstream(prefix: str, name: str, default_model: str) -> Upstream:
    return Upstream(
        name=name,
        base_url=os.environ.get(f"{prefix}_BASE_URL", "").strip().rstrip("/"),
        api_key=os.environ.get(f"{prefix}_API_KEY", "").strip(),
        model=os.environ.get(f"{prefix}_MODEL", default_model).strip(),
    )

PRIMARY = _upstream("LITEROUTER_PRIMARY", "primary", "deepseek:free")
SECONDARY = _upstream("LITEROUTER_SECONDARY", "secondary", "deepseek:free")
TIMEOUT_SECONDS = float(os.environ.get("UPSTREAM_TIMEOUT_SECONDS", "90"))
MAX_MESSAGES = int(os.environ.get("MAX_MESSAGES", "80"))
MAX_CONTENT_CHARS = int(os.environ.get("MAX_CONTENT_CHARS", "16000"))
if not 5 <= TIMEOUT_SECONDS <= 600:
    raise RuntimeError("UPSTREAM_TIMEOUT_SECONDS must be between 5 and 600")
if not 1 <= MAX_MESSAGES <= 200 or not 100 <= MAX_CONTENT_CHARS <= 64000:
    raise RuntimeError("MAX_MESSAGES or MAX_CONTENT_CHARS is outside safe bounds")

app = FastAPI(title=APP_NAME, version="1.0.0", docs_url=None, redoc_url=None, openapi_url=None)
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.environ.get("CORS_ORIGINS", "").split(",") if os.environ.get("CORS_ORIGINS") else [],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)

class Message(BaseModel):
    model_config = ConfigDict(extra="forbid")
    role: Literal["system", "user", "assistant"]
    content: str = Field(min_length=1, max_length=MAX_CONTENT_CHARS)

class ChatRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    messages: list[Message] = Field(min_length=1, max_length=MAX_MESSAGES)
    temperature: float = Field(default=0.4, ge=0.0, le=2.0)
    max_tokens: int = Field(default=2048, ge=1, le=16384)

    @field_validator("messages")
    @classmethod
    def require_user_message(cls, messages: list[Message]) -> list[Message]:
        if not any(m.role == "user" for m in messages):
            raise ValueError("At least one user message is required")
        return messages

class ChatResponse(BaseModel):
    content: str
    server: str
    model: str
    fallback_used: bool
    latency_ms: int

async def _request_upstream(upstream: Upstream, payload: dict[str, Any]) -> str:
    if not upstream.configured:
        raise RuntimeError(f"{upstream.name} server is not configured")
    parsed_endpoint = urlsplit(upstream.base_url)
    if (parsed_endpoint.scheme != "https" or not parsed_endpoint.hostname
            or parsed_endpoint.username or parsed_endpoint.password
            or parsed_endpoint.query or parsed_endpoint.fragment):
        raise RuntimeError(f"{upstream.name} endpoint must be a clean HTTPS URL")
    request_payload = dict(payload)
    request_payload["model"] = upstream.model
    timeout = httpx.Timeout(TIMEOUT_SECONDS, connect=min(15.0, TIMEOUT_SECONDS))
    response_body = bytearray()
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=False, trust_env=False,
                                 limits=httpx.Limits(max_connections=20, max_keepalive_connections=10)) as client:
        async with client.stream(
            "POST", f"{upstream.base_url}/chat/completions",
            headers={"Authorization": f"Bearer {upstream.api_key}", "Content-Type": "application/json"},
            json=request_payload,
        ) as response:
            if response.status_code in (401, 403):
                raise PermissionError(f"{upstream.name} rejected server credentials (HTTP {response.status_code})")
            if response.status_code in (404, 429) or response.status_code >= 500:
                raise ConnectionError(f"{upstream.name} temporarily unavailable (HTTP {response.status_code})")
            if not response.is_success:
                raise ValueError(f"{upstream.name} rejected request (HTTP {response.status_code})")
            async for chunk in response.aiter_bytes():
                response_body.extend(chunk)
                if len(response_body) > 8 * 1024 * 1024:
                    raise RuntimeError(f"{upstream.name} response exceeded the 8 MiB limit")
    try:
        data = json.loads(response_body)
        content = data["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError):
        raise RuntimeError(f"{upstream.name} returned an invalid chat response") from None
    if not isinstance(content, str) or not content.strip():
        raise RuntimeError(f"{upstream.name} returned an empty response")
    return content

async def route_chat(payload: ChatRequest) -> ChatResponse:
    request_data = {
        "messages": [message.model_dump() for message in payload.messages],
        "temperature": payload.temperature,
        "max_tokens": payload.max_tokens,
        "stream": False,
    }
    started = time.perf_counter()
    primary_error: Exception | None = None
    try:
        content = await _request_upstream(PRIMARY, request_data)
        return ChatResponse(content=content, server=PRIMARY.name, model=PRIMARY.model,
                            fallback_used=False, latency_ms=int((time.perf_counter()-started)*1000))
    except PermissionError:
        raise HTTPException(status_code=502, detail="Primary server authentication failed; check its server-side API key") from None
    except ValueError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from None
    except Exception as exc:
        primary_error = exc
    try:
        content = await _request_upstream(SECONDARY, request_data)
        return ChatResponse(content=content, server=SECONDARY.name, model=SECONDARY.model,
                            fallback_used=True, latency_ms=int((time.perf_counter()-started)*1000))
    except PermissionError:
        raise HTTPException(status_code=502, detail="Secondary server authentication failed; check its server-side API key") from None
    except Exception:
        primary_label = type(primary_error).__name__ if primary_error else "Unavailable"
        raise HTTPException(status_code=503, detail=f"Both AI servers are unavailable (primary: {primary_label}; secondary: unavailable)") from None

@app.get("/health")
async def health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": APP_NAME,
        "primary_configured": PRIMARY.configured,
        "secondary_configured": SECONDARY.configured,
        "failover_enabled": PRIMARY.configured and SECONDARY.configured,
    }

@app.post("/v1/chat/completions", response_model=ChatResponse)
async def chat(payload: ChatRequest) -> ChatResponse:
    return await route_chat(payload)

@app.post("/v1/chat/completions/stream")
async def chat_stream(payload: ChatRequest) -> StreamingResponse:
    result = await route_chat(payload)
    async def events():
        # Upstream inference completes before headers are sent, so primary failure
        # can safely trigger secondary failover. The client still receives SSE deltas.
        for offset in range(0, len(result.content), 48):
            chunk = result.content[offset:offset + 48]
            yield f"data: {json.dumps({'content': chunk, 'server': result.server, 'fallback_used': result.fallback_used})}\n\n"
        yield "data: [DONE]\n\n"
    return StreamingResponse(events(), media_type="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
