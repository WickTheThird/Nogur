import asyncio
import base64
from collections import defaultdict
from collections.abc import AsyncIterator, Iterator
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from uuid import uuid4

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from starlette.websockets import WebSocketDisconnect

from app.db import Base, get_db
from app.main import app
from app.redis import get_redis

API = "/v1"


class FakePubSub:
    def __init__(self, redis: "FakeRedis") -> None:
        self.redis = redis
        self.channels: set[str] = set()
        self.queue: asyncio.Queue[dict[str, str]] = asyncio.Queue()

    async def __aenter__(self) -> "FakePubSub":
        return self

    async def __aexit__(self, *_: object) -> None:
        for channel in self.channels:
            self.redis.subscribers[channel].discard(self.queue)

    async def subscribe(self, *channels: str) -> None:
        for channel in channels:
            self.channels.add(channel)
            self.redis.subscribers[channel].add(self.queue)

    async def listen(self) -> AsyncIterator[dict[str, str]]:
        while True:
            yield await self.queue.get()


class FakeRedis:
    def __init__(self) -> None:
        self.values: dict[str, str] = {}
        self.subscribers: dict[str, set[asyncio.Queue[dict[str, str]]]] = defaultdict(
            set
        )

    async def set(self, key: str, value: str, **_: object) -> None:
        self.values[key] = value

    async def get(self, key: str) -> str | None:
        return self.values.get(key)

    async def getdel(self, key: str) -> str | None:
        return self.values.pop(key, None)

    async def delete(self, key: str) -> None:
        self.values.pop(key, None)

    async def incr(self, key: str) -> int:
        value = int(self.values.get(key, "0")) + 1
        self.values[key] = str(value)
        return value

    async def expire(self, _: str, __: int) -> bool:
        return True

    async def ping(self) -> bool:
        return True

    async def publish(self, channel: str, value: str) -> int:
        queues = list(self.subscribers[channel])
        for queue in queues:
            await queue.put({"type": "message", "data": value})
        return len(queues)

    def pubsub(self) -> FakePubSub:
        return FakePubSub(self)


@pytest.fixture
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    fake_redis = FakeRedis()

    async def prepare_database() -> None:
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    async def override_db() -> AsyncIterator[Any]:
        async with sessions() as session:
            yield session

    asyncio.run(prepare_database())
    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_redis] = lambda: fake_redis
    monkeypatch.setattr("app.presence.get_redis", lambda: fake_redis)
    monkeypatch.setattr("app.device_identity.get_redis", lambda: fake_redis)
    monkeypatch.setattr("app.realtime.get_redis", lambda: fake_redis)
    monkeypatch.setattr("app.rate_limit.get_redis", lambda: fake_redis)
    monkeypatch.setattr("app.api.routes.websocket.get_redis", lambda: fake_redis)

    with TestClient(app) as test_client:
        yield test_client

    app.dependency_overrides.clear()
    asyncio.run(engine.dispose())


def authorization(
    token: str,
    device_id: str | None = None,
    device_token: str | None = None,
) -> dict[str, str]:
    headers = {"Authorization": f"Bearer {token}"}
    if device_id is not None:
        headers["X-Device-ID"] = device_id
    if device_token is not None:
        headers["X-Device-Token"] = device_token
    return headers


def register_user(client: TestClient) -> dict[str, object]:
    response = client.post(
        f"{API}/auth/register",
        json={"email": "owner@example.com", "password": "very-secret"},
    )
    assert response.status_code == 201
    return response.json()


def register_device(client: TestClient, token: str, name: str) -> dict[str, object]:
    private_key = Ed25519PrivateKey.generate()
    raw_public_key = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    response = client.post(
        f"{API}/devices/register",
        headers=authorization(token),
        json={
            "name": name,
            "platform": "macos",
            "public_key": base64.b64encode(raw_public_key).decode(),
        },
    )
    assert response.status_code == 201
    device = response.json()

    challenge_response = client.post(
        f"{API}/devices/{device['id']}/challenge",
        headers=authorization(token),
    )
    assert challenge_response.status_code == 200
    challenge = base64.b64decode(challenge_response.json()["challenge"])
    signature = base64.b64encode(private_key.sign(challenge)).decode()
    verification = client.post(
        f"{API}/devices/{device['id']}/verify",
        headers=authorization(token),
        json={"signature": signature},
    )
    assert verification.status_code == 200
    device["device_token"] = verification.json()["device_token"]
    device["verified_at"] = verification.json()["device"]["verified_at"]
    return device


def create_ticket(
    client: TestClient,
    token: str,
    device_id: str,
    device_token: str,
) -> str:
    response = client.post(
        f"{API}/realtime/tickets",
        headers=authorization(token, device_id, device_token),
    )
    assert response.status_code == 200
    return response.json()["ticket"]


def signal_event(
    event_type: str,
    *,
    session_id: str | None = None,
    payload: dict[str, object] | None = None,
) -> dict[str, object]:
    return {
        "version": 1,
        "event_id": str(uuid4()),
        "type": event_type,
        "session_id": session_id,
        "sent_at": datetime.now(UTC).isoformat(),
        "payload": payload or {},
    }


def test_root(client: TestClient) -> None:
    response = client.get("/")

    assert response.status_code == 200
    assert response.json()["docs"] == "/docs"
    assert response.json()["health"] == "/v1/health"

    versioned_health = client.get("/v1/health")
    legacy_health = client.get("/health")
    assert versioned_health.status_code == 200
    assert legacy_health.status_code == 200


def test_private_routes_require_credentials(client: TestClient) -> None:
    missing = client.get(f"{API}/devices")
    invalid = client.get(
        f"{API}/devices",
        headers={"Authorization": "Bearer not-a-valid-token"},
    )

    assert missing.status_code == 401
    assert missing.headers["www-authenticate"] == "Bearer"
    assert invalid.status_code == 401

    with pytest.raises(WebSocketDisconnect) as disconnect:
        with client.websocket_connect(f"{API}/ws"):
            pass
    assert disconnect.value.code == 4401


def test_session_validation(client: TestClient) -> None:
    tokens = register_user(client)
    access_token = str(tokens["access_token"])
    source = register_device(client, access_token, "Controller")
    target = register_device(client, access_token, "Target")

    unbound = client.post(
        f"{API}/sessions",
        headers=authorization(access_token, str(source["id"])),
        json={
            "target_device_id": target["id"],
            "requested_capabilities": ["screen.view"],
        },
    )
    assert unbound.status_code == 403

    created = client.post(
        f"{API}/sessions",
        headers=authorization(
            access_token,
            str(source["id"]),
            str(source["device_token"]),
        ),
        json={
            "target_device_id": target["id"],
            "requested_capabilities": ["screen.view", "input.pointer"],
        },
    )
    assert created.status_code == 201

    invalid_accept = client.post(
        f"{API}/sessions/{created.json()['id']}/accept",
        headers=authorization(
            access_token,
            str(target["id"]),
            str(target["device_token"]),
        ),
        json={"approved_capabilities": ["input.keyboard"]},
    )
    assert invalid_accept.status_code == 422

    early_transport = client.post(
        f"{API}/sessions/{created.json()['id']}/transport",
        headers=authorization(
            access_token,
            str(source["id"]),
            str(source["device_token"]),
        ),
    )
    assert early_transport.status_code == 409


def test_unverified_targets_are_rejected_and_revocation_ends_sessions(
    client: TestClient,
) -> None:
    tokens = register_user(client)
    access_token = str(tokens["access_token"])
    source = register_device(client, access_token, "Controller")

    unverified_key = Ed25519PrivateKey.generate().public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    unverified = client.post(
        f"{API}/devices/register",
        headers=authorization(access_token),
        json={
            "name": "Unverified",
            "platform": "macos",
            "public_key": base64.b64encode(unverified_key).decode(),
        },
    )
    assert unverified.status_code == 201
    rejected_target = client.post(
        f"{API}/sessions",
        headers=authorization(
            access_token,
            str(source["id"]),
            str(source["device_token"]),
        ),
        json={
            "target_device_id": unverified.json()["id"],
            "requested_capabilities": ["screen.view"],
        },
    )
    assert rejected_target.status_code == 404

    target = register_device(client, access_token, "Target")
    created = client.post(
        f"{API}/sessions",
        headers=authorization(
            access_token,
            str(source["id"]),
            str(source["device_token"]),
        ),
        json={
            "target_device_id": target["id"],
            "requested_capabilities": ["screen.view", "input.pointer"],
        },
    )
    assert created.status_code == 201
    session_id = created.json()["id"]
    accepted = client.post(
        f"{API}/sessions/{session_id}/accept",
        headers=authorization(
            access_token,
            str(target["id"]),
            str(target["device_token"]),
        ),
        json={"approved_capabilities": ["screen.view"]},
    )
    assert accepted.status_code == 200

    revoked = client.delete(
        f"{API}/devices/{target['id']}",
        headers=authorization(access_token),
    )
    assert revoked.status_code == 204

    ended = client.get(
        f"{API}/sessions/{session_id}",
        headers=authorization(
            access_token,
            str(source["id"]),
            str(source["device_token"]),
        ),
    )
    assert ended.status_code == 200
    assert ended.json()["status"] == "ended"
    assert ended.json()["end_reason"] == "device_revoked"


def test_auth_sessions_transport_and_websocket_signaling(
    client: TestClient,
) -> None:
    tokens = register_user(client)
    access_token = str(tokens["access_token"])

    login = client.post(
        f"{API}/auth/login",
        json={"email": "OWNER@example.com", "password": "very-secret"},
    )
    assert login.status_code == 200

    refresh = client.post(
        f"{API}/auth/refresh",
        json={"refresh_token": tokens["refresh_token"]},
    )
    assert refresh.status_code == 200

    source = register_device(client, access_token, "Controller")
    target = register_device(client, access_token, "Target")

    devices = client.get(
        f"{API}/devices",
        headers=authorization(access_token),
    )
    assert devices.status_code == 200
    assert len(devices.json()) == 2
    assert all(device["online"] is False for device in devices.json())

    created = client.post(
        f"{API}/sessions",
        headers=authorization(
            access_token,
            str(source["id"]),
            str(source["device_token"]),
        ),
        json={
            "target_device_id": target["id"],
            "requested_capabilities": ["screen.view", "input.pointer"],
            "capture": {
                "type": "display",
                "preferred_width": 1920,
                "preferred_height": 1080,
                "preferred_fps": 30,
            },
        },
    )
    assert created.status_code == 201
    session_id = created.json()["id"]
    assert created.json()["status"] == "pending"

    accepted = client.post(
        f"{API}/sessions/{session_id}/accept",
        headers=authorization(
            access_token,
            str(target["id"]),
            str(target["device_token"]),
        ),
        json={"approved_capabilities": ["screen.view", "input.pointer"]},
    )
    assert accepted.status_code == 200
    assert accepted.json()["status"] == "accepted"
    assert accepted.json()["accepted_at"] is not None

    transport = client.post(
        f"{API}/sessions/{session_id}/transport",
        headers=authorization(
            access_token,
            str(source["id"]),
            str(source["device_token"]),
        ),
    )
    assert transport.status_code == 200
    assert transport.json()["ice_servers"][0]["urls"] == [
        "stun:stun.l.google.com:19302"
    ]

    source_ticket = create_ticket(
        client,
        access_token,
        str(source["id"]),
        str(source["device_token"]),
    )
    target_ticket = create_ticket(
        client,
        access_token,
        str(target["id"]),
        str(target["device_token"]),
    )

    with client.websocket_connect(f"{API}/ws?ticket={source_ticket}") as source_socket:
        source_connected = source_socket.receive_json()
        assert source_connected["type"] == "device.connected"

        with client.websocket_connect(
            f"{API}/ws?ticket={target_ticket}"
        ) as target_socket:
            target_connected = target_socket.receive_json()
            assert target_connected["type"] == "device.connected"

            source_socket.send_json(
                signal_event(
                    "webrtc.offer",
                    session_id=session_id,
                    payload={"sdp": "v=0\r\n"},
                )
            )
            assert source_socket.receive_json()["type"] == "session.connecting"
            assert target_socket.receive_json()["type"] == "session.connecting"
            offer = target_socket.receive_json()
            assert offer["type"] == "webrtc.offer"
            assert offer["payload"]["sdp"] == "v=0\r\n"

            target_socket.send_json(
                signal_event(
                    "webrtc.answer",
                    session_id=session_id,
                    payload={"sdp": "v=0\r\na=answer\r\n"},
                )
            )
            answer = source_socket.receive_json()
            assert answer["type"] == "webrtc.answer"

            target_socket.send_json(
                signal_event("session.active", session_id=session_id)
            )
            assert source_socket.receive_json()["type"] == "session.active"
            assert target_socket.receive_json()["type"] == "session.active"

            ended = client.post(
                f"{API}/sessions/{session_id}/end",
                headers=authorization(
                    access_token,
                    str(source["id"]),
                    str(source["device_token"]),
                ),
                json={"reason": "controller_closed"},
            )
            assert ended.status_code == 200
            assert ended.json()["status"] == "ended"
            assert ended.json()["end_reason"] == "controller_closed"
            assert source_socket.receive_json()["type"] == "session.ended"
            assert target_socket.receive_json()["type"] == "session.ended"

    with pytest.raises(WebSocketDisconnect) as replay:
        with client.websocket_connect(f"{API}/ws?ticket={source_ticket}"):
            pass
    assert replay.value.code == 4401

    audit = client.get(
        f"{API}/sessions/{session_id}/events",
        headers=authorization(
            access_token,
            str(source["id"]),
            str(source["device_token"]),
        ),
    )
    assert audit.status_code == 200
    assert [event["event_type"] for event in audit.json()] == [
        "session.requested",
        "session.accepted",
        "session.connecting",
        "session.active",
        "session.ended",
    ]
    assert all("sdp" not in event["payload"] for event in audit.json())

    deleted = client.delete(
        f"{API}/devices/{target['id']}",
        headers=authorization(access_token),
    )
    assert deleted.status_code == 204
