import hashlib
import json
import secrets
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID, uuid4

from app.config import get_settings
from app.redis import get_redis


def device_channel(device_id: UUID) -> str:
    return f"nogur:events:device:{device_id}"


def ticket_key(ticket: str) -> str:
    digest = hashlib.sha256(ticket.encode()).hexdigest()
    return f"nogur:ws-ticket:{digest}"


def utc_iso(value: datetime | None = None) -> str:
    current = value or datetime.now(UTC)
    return current.isoformat().replace("+00:00", "Z")


def make_event(
    event_type: str,
    *,
    session_id: UUID | None = None,
    payload: dict[str, Any] | None = None,
    event_id: UUID | None = None,
) -> dict[str, Any]:
    return {
        "version": 1,
        "event_id": str(event_id or uuid4()),
        "type": event_type,
        "session_id": str(session_id) if session_id else None,
        "sent_at": utc_iso(),
        "payload": payload or {},
    }


async def publish_device_event(device_id: UUID, event: dict[str, Any]) -> None:
    await get_redis().publish(device_channel(device_id), json.dumps(event))


async def create_websocket_ticket(
    user_id: UUID, device_id: UUID
) -> tuple[str, datetime]:
    settings = get_settings()
    ticket = secrets.token_urlsafe(32)
    expires_at = datetime.now(UTC) + timedelta(
        seconds=settings.websocket_ticket_ttl_seconds
    )
    value = json.dumps({"user_id": str(user_id), "device_id": str(device_id)})
    await get_redis().set(
        ticket_key(ticket),
        value,
        ex=settings.websocket_ticket_ttl_seconds,
    )
    return ticket, expires_at


async def consume_websocket_ticket(
    ticket: str,
) -> tuple[UUID, UUID] | None:
    raw = await get_redis().getdel(ticket_key(ticket))
    if raw is None:
        return None
    try:
        value = json.loads(raw)
        return UUID(value["user_id"]), UUID(value["device_id"])
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None
