import asyncio
from collections.abc import AsyncIterator, Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from starlette.websockets import WebSocketDisconnect

from app.db import Base, get_db
from app.main import app
from app.redis import get_redis


class FakeRedis:
    def __init__(self) -> None:
        self.values: dict[str, str] = {}

    async def set(self, key: str, value: str, **_: object) -> None:
        self.values[key] = value

    async def get(self, key: str) -> str | None:
        return self.values.get(key)

    async def delete(self, key: str) -> None:
        self.values.pop(key, None)

    async def ping(self) -> bool:
        return True


@pytest.fixture
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    fake_redis = FakeRedis()

    async def prepare_database() -> None:
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)

    async def override_db() -> AsyncIterator[object]:
        async with sessions() as session:
            yield session

    asyncio.run(prepare_database())
    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_redis] = lambda: fake_redis
    monkeypatch.setattr("app.presence.get_redis", lambda: fake_redis)

    with TestClient(app) as test_client:
        yield test_client

    app.dependency_overrides.clear()
    asyncio.run(engine.dispose())


def authorization(token: str, device_id: str | None = None) -> dict[str, str]:
    headers = {"Authorization": f"Bearer {token}"}
    if device_id is not None:
        headers["X-Device-ID"] = device_id
    return headers


def register_user(client: TestClient) -> dict[str, object]:
    response = client.post(
        "/auth/register",
        json={"email": "owner@example.com", "password": "very-secret"},
    )
    assert response.status_code == 201
    return response.json()


def register_device(
    client: TestClient, token: str, name: str, public_key: str
) -> dict[str, object]:
    response = client.post(
        "/devices/register",
        headers=authorization(token),
        json={"name": name, "platform": "macos", "public_key": public_key},
    )
    assert response.status_code == 201
    return response.json()


def test_root(client: TestClient) -> None:
    response = client.get("/")

    assert response.status_code == 200
    assert response.json()["docs"] == "/docs"
    assert response.json()["health"] == "/health"


def test_private_routes_require_bearer_credentials(client: TestClient) -> None:
    missing = client.get("/devices")
    invalid = client.get(
        "/devices", headers={"Authorization": "Bearer not-a-valid-token"}
    )

    assert missing.status_code == 401
    assert missing.headers["www-authenticate"] == "Bearer"
    assert invalid.status_code == 401

    with pytest.raises(WebSocketDisconnect) as disconnect:
        with client.websocket_connect("/ws"):
            pass
    assert disconnect.value.code == 4401


def test_auth_devices_sessions_and_websocket(client: TestClient) -> None:
    tokens = register_user(client)
    access_token = str(tokens["access_token"])

    login = client.post(
        "/auth/login",
        json={"email": "OWNER@example.com", "password": "very-secret"},
    )
    assert login.status_code == 200

    refresh = client.post(
        "/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
    )
    assert refresh.status_code == 200

    source = register_device(client, access_token, "Controller", "source-key")
    target = register_device(client, access_token, "Target", "target-key")

    devices = client.get("/devices", headers=authorization(access_token))
    assert devices.status_code == 200
    assert len(devices.json()) == 2

    created = client.post(
        "/sessions",
        headers=authorization(access_token, str(source["id"])),
        json={"target_device_id": target["id"]},
    )
    assert created.status_code == 201
    assert created.json()["status"] == "pending"

    accepted = client.post(
        f"/sessions/{created.json()['id']}/accept",
        headers=authorization(access_token, str(target["id"])),
    )
    assert accepted.status_code == 200
    assert accepted.json()["status"] == "accepted"
    assert accepted.json()["accepted_at"] is not None

    with client.websocket_connect(
        "/ws", headers=authorization(access_token, str(target["id"]))
    ) as websocket:
        assert websocket.receive_json() == {
            "type": "connected",
            "device_id": target["id"],
        }
        websocket.send_json({"type": "ping"})
        assert websocket.receive_json() == {"type": "pong"}

    ended = client.post(
        f"/sessions/{created.json()['id']}/end",
        headers=authorization(access_token, str(source["id"])),
    )
    assert ended.status_code == 200
    assert ended.json()["status"] == "ended"

    deleted = client.delete(
        f"/devices/{target['id']}", headers=authorization(access_token)
    )
    assert deleted.status_code == 204
