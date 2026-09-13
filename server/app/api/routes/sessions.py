from datetime import UTC, datetime
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.dependencies import get_current_device, get_current_user
from app.models import Device, RemoteSession, User
from app.schemas import SessionCreateRequest, SessionResponse

router = APIRouter(prefix="/sessions", tags=["sessions"])


async def owned_session(
    session_id: UUID, user: User, db: AsyncSession
) -> RemoteSession:
    session = await db.scalar(
        select(RemoteSession)
        .where(RemoteSession.id == session_id, RemoteSession.user_id == user.id)
        .with_for_update()
    )
    if session is None:
        raise HTTPException(status_code=404, detail="Session not found")
    return session


@router.post("", response_model=SessionResponse, status_code=201)
async def create_session(
    body: SessionCreateRequest,
    source: Annotated[Device, Depends(get_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> RemoteSession:
    target = await db.get(Device, body.target_device_id)
    if target is None or target.user_id != user.id or target.revoked_at is not None:
        raise HTTPException(status_code=404, detail="Target device not found")
    if source.id == target.id:
        raise HTTPException(status_code=422, detail="Source and target must differ")

    session = RemoteSession(
        user_id=user.id,
        source_device_id=source.id,
        target_device_id=target.id,
        status="pending",
    )
    db.add(session)
    await db.commit()
    await db.refresh(session)
    return session


async def transition_session(
    session_id: UUID,
    action: Literal["accept", "reject", "end"],
    device: Device,
    user: User,
    db: AsyncSession,
) -> RemoteSession:
    session = await owned_session(session_id, user, db)
    now = datetime.now(UTC)

    if action in {"accept", "reject"}:
        if device.id != session.target_device_id:
            raise HTTPException(
                status_code=403, detail="Only the target device can respond"
            )
        if session.status != "pending":
            raise HTTPException(status_code=409, detail="Session is not pending")
        if action == "accept":
            session.status = "accepted"
            session.accepted_at = now
        else:
            session.status = "rejected"
            session.ended_at = now
    else:
        if device.id not in {session.source_device_id, session.target_device_id}:
            raise HTTPException(
                status_code=403, detail="Device is not part of this session"
            )
        if session.status not in {"pending", "accepted"}:
            raise HTTPException(status_code=409, detail="Session has already ended")
        session.status = "ended"
        session.ended_at = now

    await db.commit()
    await db.refresh(session)
    return session


@router.post("/{session_id}/accept", response_model=SessionResponse)
async def accept_session(
    session_id: UUID,
    device: Annotated[Device, Depends(get_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> RemoteSession:
    return await transition_session(session_id, "accept", device, user, db)


@router.post("/{session_id}/reject", response_model=SessionResponse)
async def reject_session(
    session_id: UUID,
    device: Annotated[Device, Depends(get_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> RemoteSession:
    return await transition_session(session_id, "reject", device, user, db)


@router.post("/{session_id}/end", response_model=SessionResponse)
async def end_session(
    session_id: UUID,
    device: Annotated[Device, Depends(get_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> RemoteSession:
    return await transition_session(session_id, "end", device, user, db)
