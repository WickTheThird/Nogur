from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.models import Device, User
from app.presence import presence_manager
from app.security import InvalidTokenError, decode_token

router = APIRouter(tags=["websockets"])


@router.websocket("/ws")
async def websocket_endpoint(
    websocket: WebSocket,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> None:
    authorization = websocket.headers.get("authorization", "")
    raw_device_id = websocket.headers.get("x-device-id")
    if not authorization.lower().startswith("bearer ") or raw_device_id is None:
        await websocket.close(code=4401, reason="Missing credentials")
        return
    try:
        token = decode_token(authorization[7:].strip(), "access")
        device_id = UUID(raw_device_id)
    except (InvalidTokenError, ValueError):
        await websocket.close(code=4401, reason="Invalid credentials")
        return

    user = await db.get(User, token.sub)
    device = await db.get(Device, device_id)
    if (
        user is None
        or device is None
        or device.user_id != user.id
        or device.revoked_at is not None
    ):
        await websocket.close(code=4403, reason="Unknown or revoked device")
        return

    device.last_seen_at = datetime.now(UTC)
    await db.commit()
    await presence_manager.connect(device.id, user.id, websocket)
    await websocket.send_json({"type": "connected", "device_id": str(device.id)})
    try:
        while True:
            message = await websocket.receive_json()
            await presence_manager.refresh(device.id, user.id)
            if message.get("type") == "ping":
                await websocket.send_json({"type": "pong"})
            else:
                await websocket.send_json(
                    {"type": "error", "detail": "Unsupported message type"}
                )
    except WebSocketDisconnect:
        pass
    finally:
        await presence_manager.disconnect(device.id, websocket)
