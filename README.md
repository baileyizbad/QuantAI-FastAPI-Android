# QuantAI Android + FastAPI

QuantAI is a Flutter Android client that talks directly to a local FastAPI service at the fixed address `http://127.0.0.1:8080`.

## Architecture

```text
QuantAI Android app
       |
       | HTTP, no app token or Bearer header
       v
FastAPI: http://127.0.0.1:8080
       |
       +--> Primary OpenAI-compatible inference endpoint
       |
       +--> Secondary inference endpoint (fallback)
```

The Android client has no editable API URL, gateway URL, app access token, secure-token storage, or gateway authentication. The FastAPI service retains provider API keys on the server in its environment; do not put provider credentials in the Android application.

## 1. Configure the FastAPI service

From the `server/` directory:

```bash
cp .env.example .env
```

Set the primary and secondary OpenAI-compatible inference endpoint URLs, provider API keys, and model IDs in `.env`. The primary endpoint is attempted first; the secondary is used as a fallback for availability failures. Keep `.env` private and out of source control.

Install and run:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8080
```

Health check:

```bash
curl http://127.0.0.1:8080/health
```

Or run with Docker Compose:

```bash
docker compose up --build -d
```

The Compose port is bound to host loopback (`127.0.0.1:8080`). The API has no app-level Bearer-token authentication and should remain on a trusted local interface; do not expose it to an untrusted network without adding appropriate access controls.

## 2. API

- `GET /health` reports service and inference-provider configuration status.
- `POST /v1/chat/completions` accepts `messages`, optional `temperature`, and optional `max_tokens`, and returns a JSON chat response.

Example:

```bash
curl -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Hello"}]}'
```

No `Authorization` header is required by the local FastAPI app.

## 3. Android application

Build the APK from `flutter_app/`:

```bash
flutter pub get
flutter build apk --release
```

The client uses the fixed base URL `http://127.0.0.1:8080`; no URL or token setup is required in the app. Android cleartext HTTP is enabled for this local endpoint.

**Important loopback behavior:** on a physical Android device, `127.0.0.1` means the Android device itself. FastAPI must therefore run on that same device and listen on port `8080`. In the standard Android emulator, `127.0.0.1` refers to the emulator, not the development computer; the requested fixed endpoint will only work if FastAPI is running inside the emulator environment.

## 4. Tests

```bash
cd server
pip install -r requirements-dev.txt
pytest -q
```

The tests cover unauthenticated local FastAPI access, request validation, primary/secondary failover, upstream JSON parsing, and malformed upstream responses.
