# Nogur Server

FastAPI broker API using PostgreSQL, SQLAlchemy 2.x, Alembic, Redis,
WebSockets, Pydantic, uv, and Docker Compose.

## Start

```bash
docker compose up --build
```

Compose runs the Alembic migration before starting the API.

Then open:

- API docs: <http://localhost:8000/docs>
- Health check: <http://localhost:8000/health>
- WebSocket: `ws://localhost:8000/ws`

For local development outside Docker:

```bash
docker compose up -d postgres redis
cp .env.example .env
uv sync
uv run alembic upgrade head
uv run uvicorn app.main:app --reload
```

## Authentication

Register and log in with JSON requests:

```text
POST /auth/register
POST /auth/login
POST /auth/refresh
```

Registration and login return an access token and refresh token. Send the
access token to protected endpoints as:

```http
Authorization: Bearer <access-token>
```

Device-specific session operations also require:

```http
X-Device-ID: <device-uuid>
```

## WebSocket presence

Connect an already registered, non-revoked device to `/ws` with both headers:

```http
Authorization: Bearer <access-token>
X-Device-ID: <device-uuid>
```

The production URL is `wss://api.nogur.bumbuindustries.com/ws`. On connection,
the server records `nogur:presence:<device-uuid>` in Redis with a 120-second
TTL. Clients should send `{"type":"ping"}` at least once per minute. The server
responds with `{"type":"pong"}` and refreshes the presence TTL.

Browser JavaScript cannot attach arbitrary headers to the native `WebSocket`
constructor. This header-based handshake is intended for the native device
agent. A browser client will need a short-lived WebSocket ticket endpoint in a
later signaling phase.

## Database migrations

Import new SQLAlchemy models in `app/models/__init__.py`, then run:

```bash
uv run alembic revision --autogenerate -m "describe the change"
uv run alembic upgrade head
```

## Checks

```bash
uv run ruff check .
uv run pytest
```
