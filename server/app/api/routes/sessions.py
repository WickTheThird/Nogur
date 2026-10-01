import base64
import hashlib
import hmac
import time
from datetime import UTC, datetime, timedelta
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_db
from app.dependencies import get_current_user, get_verified_current_device
from app.models import Device, RemoteSession, SessionEvent, User
from app.rate_limit import enforce_rate_limit
from app.realtime import make_event, publish_device_event
from app.schemas import (
    IceServer,
    SessionAcceptRequest,
    SessionCreateRequest,
    SessionEndRequest,
    SessionEventResponse,
    SessionResponse,
    SessionTransportResponse,
)
from app.session_audit import record_session_event

router = APIRouter(prefix="/sessions", tags=["sessions"])

TERMINAL_STATUSES = {"rejected", "expired", "failed", "ended"}


def as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


async def notify_session_devices(
    session: RemoteSession,
    event_type: str,
    payload: dict[str, object] | None = None,
) -> None:
    event = make_event(
        event_type,
        session_id=session.id,
        payload=payload,
    )
    await publish_device_event(session.source_device_id, event)
    await publish_device_event(session.target_device_id, event)


async def owned_session(
    session_id: UUID,
    user: User,
    db: AsyncSession,
    *,
    lock: bool = False,
) -> RemoteSession:
    query = select(RemoteSession).where(
        RemoteSession.id == session_id,
        RemoteSession.user_id == user.id,
    )
    if lock:
        query = query.with_for_update()
    session = await db.scalar(query)
    if session is None:
        raise HTTPException(status_code=404, detail="Session not found")
    if session.status == "pending" and as_utc(session.expires_at) <= datetime.now(UTC):
        session.status = "expired"
        session.ended_at = datetime.now(UTC)
        session.end_reason = "request_expired"
        record_session_event(db, session, "session.expired")
        await db.commit()
        await db.refresh(session)
        await notify_session_devices(session, "session.expired")
    return session


@router.post("", response_model=SessionResponse, status_code=201)
async def create_session(
    body: SessionCreateRequest,
    request: Request,
    source: Annotated[Device, Depends(get_verified_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> RemoteSession:
    target = await db.get(Device, body.target_device_id)
    if target is None or target.user_id != user.id or target.revoked_at is not None:
        raise HTTPException(status_code=404, detail="Target device not found")
    if source.id == target.id:
        raise HTTPException(status_code=422, detail="Source and target must differ")

    settings = get_settings()
    await enforce_rate_limit(
        "session-create",
        str(source.id),
        limit=settings.session_create_limit_per_minute,
    )
    session = RemoteSession(
        user_id=user.id,
        source_device_id=source.id,
        target_device_id=target.id,
        status="pending",
        requested_capabilities=list(body.requested_capabilities),
        approved_capabilities=[],
        capture=body.capture.model_dump(),
        expires_at=datetime.now(UTC)
        + timedelta(seconds=settings.session_request_ttl_seconds),
        source_ip=request.client.host if request.client else None,
    )
    db.add(session)
    await db.flush()
    record_session_event(
        db,
        session,
        "session.requested",
        actor_device_id=source.id,
        payload={
            "requested_capabilities": list(body.requested_capabilities),
            "capture": body.capture.model_dump(),
        },
    )
    await db.commit()
    await db.refresh(session)

    await publish_device_event(
        target.id,
        make_event(
            "session.requested",
            session_id=session.id,
            payload=SessionResponse.model_validate(session).model_dump(mode="json"),
        ),
    )
    return session


@router.get("", response_model=list[SessionResponse])
async def list_sessions(
    device: Annotated[Device, Depends(get_verified_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[RemoteSession]:
    sessions = await db.scalars(
        select(RemoteSession)
        .where(
            RemoteSession.user_id == user.id,
            or_(
                RemoteSession.source_device_id == device.id,
                RemoteSession.target_device_id == device.id,
            ),
        )
        .order_by(RemoteSession.created_at.desc())
        .limit(100)
    )
    return list(sessions)


@router.get(
    "/{session_id}/events",
    response_model=list[SessionEventResponse],
)
async def list_session_events(
    session_id: UUID,
    device: Annotated[Device, Depends(get_verified_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[SessionEvent]:
    session = await owned_session(session_id, user, db)
    if device.id not in {session.source_device_id, session.target_device_id}:
        raise HTTPException(status_code=403, detail="Device is not part of session")
    events = await db.scalars(
        select(SessionEvent)
        .where(SessionEvent.session_id == session.id)
        .order_by(SessionEvent.created_at, SessionEvent.id)
    )
    return list(events)


@router.get("/{session_id}", response_model=SessionResponse)
async def get_session(
    session_id: UUID,
    device: Annotated[Device, Depends(get_verified_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> RemoteSession:
    session = await owned_session(session_id, user, db)
    if device.id not in {session.source_device_id, session.target_device_id}:
        raise HTTPException(status_code=403, detail="Device is not part of session")
    return session


@router.post("/{session_id}/accept", response_model=SessionResponse)
async def accept_session(
    session_id: UUID,
    body: SessionAcceptRequest,
    request: Request,
    device: Annotated[Device, Depends(get_verified_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> RemoteSession:
    session = await owned_session(session_id, user, db, lock=True)
    if device.id != session.target_device_id:
        raise HTTPException(status_code=403, detail="Only target device can accept")
    if session.status != "pending":
        raise HTTPException(status_code=409, detail=f"Session is {session.status}")

    requested = set(session.requested_capabilities)
    approved = set(body.approved_capabilities)
    if not approved.issubset(requested):
        raise HTTPException(
            status_code=422,
            detail=("Approved capabilities must be a subset of requested capabilities"),
        )

    session.status = "accepted"
    session.approved_capabilities = list(body.approved_capabilities)
    session.accepted_at = datetime.now(UTC)
    session.target_ip = request.client.host if request.client else None
    record_session_event(
        db,
        session,
        "session.accepted",
        actor_device_id=device.id,
        payload={"approved_capabilities": session.approved_capabilities},
    )
    await db.commit()
    await db.refresh(session)

    await notify_session_devices(
        session,
        "session.accepted",
        {"approved_capabilities": session.approved_capabilities},
    )
    return session


@router.post("/{session_id}/reject", response_model=SessionResponse)
async def reject_session(
    session_id: UUID,
    device: Annotated[Device, Depends(get_verified_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> RemoteSession:
    session = await owned_session(session_id, user, db, lock=True)
    if device.id != session.target_device_id:
        raise HTTPException(status_code=403, detail="Only target device can reject")
    if session.status != "pending":
        raise HTTPException(status_code=409, detail=f"Session is {session.status}")

    session.status = "rejected"
    session.ended_at = datetime.now(UTC)
    session.end_reason = "rejected_by_target"
    record_session_event(
        db,
        session,
        "session.rejected",
        actor_device_id=device.id,
    )
    await db.commit()
    await db.refresh(session)
    await notify_session_devices(session, "session.rejected")
    return session


@router.post("/{session_id}/transport", response_model=SessionTransportResponse)
async def get_session_transport(
    session_id: UUID,
    device: Annotated[Device, Depends(get_verified_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> SessionTransportResponse:
    session = await owned_session(session_id, user, db)
    if device.id not in {session.source_device_id, session.target_device_id}:
        raise HTTPException(status_code=403, detail="Device is not part of session")
    if session.status not in {"accepted", "connecting", "active"}:
        raise HTTPException(status_code=409, detail=f"Session is {session.status}")

    settings = get_settings()
    expires_unix = int(time.time()) + settings.turn_credential_ttl_seconds
    expires_at = datetime.fromtimestamp(expires_unix, tz=UTC)
    ice_servers: list[IceServer] = []

    stun_urls = [url.strip() for url in settings.stun_urls.split(",") if url.strip()]
    if stun_urls:
        ice_servers.append(IceServer(urls=stun_urls))

    turn_urls = [url.strip() for url in settings.turn_urls.split(",") if url.strip()]
    if turn_urls and not settings.turn_shared_secret:
        raise HTTPException(status_code=503, detail="TURN is not configured")
    if turn_urls:
        username = f"{expires_unix}:{session.id}:{device.id}"
        digest = hmac.new(
            settings.turn_shared_secret.encode(),
            username.encode(),
            hashlib.sha1,
        ).digest()
        credential = base64.b64encode(digest).decode()
        ice_servers.append(
            IceServer(
                urls=turn_urls,
                username=username,
                credential=credential,
            )
        )

    return SessionTransportResponse(
        expires_at=expires_at,
        ice_servers=ice_servers,
    )


@router.post("/{session_id}/end", response_model=SessionResponse)
async def end_session(
    session_id: UUID,
    body: SessionEndRequest,
    device: Annotated[Device, Depends(get_verified_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> RemoteSession:
    session = await owned_session(session_id, user, db, lock=True)
    if device.id not in {session.source_device_id, session.target_device_id}:
        raise HTTPException(status_code=403, detail="Device is not part of session")
    if session.status in TERMINAL_STATUSES:
        raise HTTPException(status_code=409, detail="Session has already ended")

    session.status = "ended"
    session.ended_at = datetime.now(UTC)
    session.end_reason = body.reason
    record_session_event(
        db,
        session,
        "session.ended",
        actor_device_id=device.id,
        payload={"reason": body.reason},
    )
    await db.commit()
    await db.refresh(session)
    await notify_session_devices(
        session,
        "session.ended",
        {"reason": session.end_reason},
    )
    return session
