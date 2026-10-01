import asyncio
import json
from contextlib import suppress
from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from pydantic import ValidationError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.models import Device, RemoteSession, User
from app.presence import presence_manager
from app.realtime import (
    consume_websocket_ticket,
    device_channel,
    make_event,
    publish_device_event,
)
from app.redis import get_redis
from app.schemas import SignalingEnvelope
from app.session_audit import record_session_event

router = APIRouter(tags=["websockets"])

MAX_SIGNAL_MESSAGE_BYTES = 1_048_576
WEBRTC_EVENTS = {
    "webrtc.offer",
    "webrtc.answer",
    "webrtc.ice_candidate",
}
SESSION_EVENTS = {"session.active", "session.failed"}


async def send_json_locked(
    websocket: WebSocket,
    lock: asyncio.Lock,
    value: dict[str, object],
) -> None:
    async with lock:
        await websocket.send_json(value)


async def pump_device_events(
    device_id: UUID,
    websocket: WebSocket,
    send_lock: asyncio.Lock,
    ready: asyncio.Event,
) -> None:
    async with get_redis().pubsub() as pubsub:
        await pubsub.subscribe(device_channel(device_id))
        ready.set()
        async for message in pubsub.listen():
            if message["type"] != "message":
                continue
            data = json.loads(message["data"])
            await send_json_locked(websocket, send_lock, data)
            if data.get("type") == "device.revoked":
                await websocket.close(code=4003, reason="Device revoked")
                return


async def send_error(
    websocket: WebSocket,
    send_lock: asyncio.Lock,
    detail: str,
    *,
    session_id: UUID | None = None,
) -> None:
    await send_json_locked(
        websocket,
        send_lock,
        make_event(
            "error",
            session_id=session_id,
            payload={"detail": detail},
        ),
    )


def valid_webrtc_payload(message: SignalingEnvelope) -> bool:
    if message.type in {"webrtc.offer", "webrtc.answer"}:
        sdp = message.payload.get("sdp")
        return isinstance(sdp, str) and 0 < len(sdp) <= MAX_SIGNAL_MESSAGE_BYTES
    candidate = message.payload.get("candidate")
    return isinstance(candidate, str) and len(candidate) <= 65_536


async def handle_session_event(
    message: SignalingEnvelope,
    session: RemoteSession,
    device_id: UUID,
    db: AsyncSession,
) -> None:
    if message.type == "session.active":
        if session.status not in {"connecting", "active"}:
            raise ValueError(f"Session is {session.status}")
        if session.status != "active":
            session.status = "active"
            session.connected_at = datetime.now(UTC)
            record_session_event(
                db,
                session,
                "session.active",
                actor_device_id=device_id,
            )
            await db.commit()
    else:
        if session.status not in {"accepted", "connecting", "active"}:
            raise ValueError(f"Session is {session.status}")
        session.status = "failed"
        session.ended_at = datetime.now(UTC)
        reason = message.payload.get("reason", "connection_failed")
        session.end_reason = str(reason)[:200]
        record_session_event(
            db,
            session,
            "session.failed",
            actor_device_id=device_id,
            payload={"reason": session.end_reason},
        )
        await db.commit()


@router.websocket("/ws")
async def websocket_endpoint(
    websocket: WebSocket,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    ticket = websocket.query_params.get("ticket")
    if not ticket:
        await websocket.close(code=4401, reason="Missing ticket")
        return

    identity = await consume_websocket_ticket(ticket)
    if identity is None:
        await websocket.close(code=4401, reason="Invalid or expired ticket")
        return

    user_id, device_id = identity
    user = await db.get(User, user_id)
    device = await db.get(Device, device_id)
    if (
        user is None
        or device is None
        or device.user_id != user.id
        or device.revoked_at is not None
    ):
        await websocket.close(code=4403, reason="Unknown or revoked device")
        return

    send_lock = asyncio.Lock()
    ready = asyncio.Event()
    device.last_seen_at = datetime.now(UTC)
    await db.commit()
    await presence_manager.connect(device.id, user.id, websocket)

    event_pump = asyncio.create_task(
        pump_device_events(device.id, websocket, send_lock, ready)
    )

    try:
        await asyncio.wait_for(ready.wait(), timeout=5)
        await send_json_locked(
            websocket,
            send_lock,
            make_event(
                "device.connected",
                payload={"device_id": str(device.id)},
            ),
        )

        while True:
            raw = await websocket.receive_text()
            if len(raw.encode()) > MAX_SIGNAL_MESSAGE_BYTES:
                await websocket.close(code=4400, reason="Message is too large")
                return

            await presence_manager.refresh(device.id, user.id)
            try:
                message = SignalingEnvelope.model_validate_json(raw)
            except ValidationError:
                await send_error(websocket, send_lock, "Invalid event envelope")
                continue

            if message.type == "ping":
                await send_json_locked(
                    websocket,
                    send_lock,
                    make_event(
                        "pong",
                        payload=message.payload,
                        event_id=message.event_id,
                    ),
                )
                continue

            if message.type not in WEBRTC_EVENTS | SESSION_EVENTS:
                await send_error(
                    websocket,
                    send_lock,
                    "Unsupported event type",
                    session_id=message.session_id,
                )
                continue
            if message.session_id is None:
                await send_error(websocket, send_lock, "session_id is required")
                continue

            session = await db.get(RemoteSession, message.session_id)
            if session is None or session.user_id != user.id:
                await send_error(
                    websocket,
                    send_lock,
                    "Session not found",
                    session_id=message.session_id,
                )
                continue
            if device.id not in {
                session.source_device_id,
                session.target_device_id,
            }:
                await send_error(
                    websocket,
                    send_lock,
                    "Device is not part of session",
                    session_id=session.id,
                )
                continue

            if message.type in SESSION_EVENTS:
                try:
                    await handle_session_event(message, session, device.id, db)
                except ValueError as error:
                    await send_error(
                        websocket,
                        send_lock,
                        str(error),
                        session_id=session.id,
                    )
                    continue
                event = make_event(
                    message.type,
                    session_id=session.id,
                    payload=message.payload,
                    event_id=message.event_id,
                )
                await publish_device_event(session.source_device_id, event)
                await publish_device_event(session.target_device_id, event)
                continue

            if session.status not in {"accepted", "connecting", "active"}:
                await send_error(
                    websocket,
                    send_lock,
                    f"Session is {session.status}",
                    session_id=session.id,
                )
                continue
            if not valid_webrtc_payload(message):
                await send_error(
                    websocket,
                    send_lock,
                    "Invalid WebRTC payload",
                    session_id=session.id,
                )
                continue
            if message.type == "webrtc.offer" and device.id != session.source_device_id:
                await send_error(
                    websocket,
                    send_lock,
                    "Only source device can send offer",
                    session_id=session.id,
                )
                continue
            if (
                message.type == "webrtc.answer"
                and device.id != session.target_device_id
            ):
                await send_error(
                    websocket,
                    send_lock,
                    "Only target device can send answer",
                    session_id=session.id,
                )
                continue

            recipient_id = (
                session.target_device_id
                if device.id == session.source_device_id
                else session.source_device_id
            )
            if message.type == "webrtc.offer" and session.status == "accepted":
                session.status = "connecting"
                record_session_event(
                    db,
                    session,
                    "session.connecting",
                    actor_device_id=device.id,
                )
                await db.commit()
                connecting = make_event(
                    "session.connecting",
                    session_id=session.id,
                )
                await publish_device_event(session.source_device_id, connecting)
                await publish_device_event(session.target_device_id, connecting)

            await publish_device_event(
                recipient_id,
                make_event(
                    message.type,
                    session_id=session.id,
                    payload=message.payload,
                    event_id=message.event_id,
                ),
            )
    except (TimeoutError, WebSocketDisconnect):
        pass
    finally:
        event_pump.cancel()
        with suppress(asyncio.CancelledError):
            await event_pump
        await presence_manager.disconnect(device.id, websocket)
