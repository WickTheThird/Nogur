from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.dependencies import get_current_user
from app.models import Device, User
from app.presence import presence_manager
from app.schemas import DeviceRegisterRequest, DeviceResponse

router = APIRouter(prefix="/devices", tags=["devices"])


async def owned_device(device_id: UUID, user: User, db: AsyncSession) -> Device:
    device = await db.get(Device, device_id)
    if device is None or device.user_id != user.id:
        raise HTTPException(status_code=404, detail="Device not found")
    return device


@router.post("/register", response_model=DeviceResponse, status_code=201)
async def register_device(
    body: DeviceRegisterRequest,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> Device:
    device = Device(user_id=user.id, **body.model_dump())
    db.add(device)
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(
            status_code=409, detail="Public key is already registered"
        ) from None
    await db.refresh(device)
    return device


@router.get("", response_model=list[DeviceResponse])
async def list_devices(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> list[Device]:
    result = await db.scalars(
        select(Device).where(Device.user_id == user.id).order_by(Device.created_at)
    )
    return list(result)


@router.get("/{device_id}", response_model=DeviceResponse)
async def get_device(
    device_id: UUID,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> Device:
    return await owned_device(device_id, user, db)


@router.delete("/{device_id}", status_code=204)
async def revoke_device(
    device_id: UUID,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> Response:
    device = await owned_device(device_id, user, db)
    if device.revoked_at is None:
        device.revoked_at = datetime.now(UTC)
        await db.commit()
    await presence_manager.disconnect_device(device.id, code=4003)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
