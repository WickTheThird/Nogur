from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_db
from app.dependencies import get_current_user
from app.device_identity import (
    InvalidDeviceKeyError,
    create_device_challenge,
    validate_public_key,
    verify_device_challenge,
)
from app.models import Device, User
from app.presence import presence_manager
from app.rate_limit import enforce_rate_limit
from app.realtime import make_event, publish_device_event
from app.schemas import (
    DeviceChallengeResponse,
    DeviceRegisterRequest,
    DeviceResponse,
    DeviceVerificationResponse,
    DeviceVerifyRequest,
)
from app.security import create_device_token

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
    try:
        validate_public_key(body.public_key)
    except InvalidDeviceKeyError:
        raise HTTPException(
            status_code=422,
            detail="Public key must be a base64 Ed25519 public key",
        ) from None
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
) -> list[DeviceResponse]:
    result = await db.scalars(
        select(Device).where(Device.user_id == user.id).order_by(Device.created_at)
    )
    devices = list(result)
    return [
        DeviceResponse.model_validate(device).model_copy(
            update={"online": await presence_manager.is_online(device.id)}
        )
        for device in devices
    ]


@router.get("/{device_id}", response_model=DeviceResponse)
async def get_device(
    device_id: UUID,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> DeviceResponse:
    device = await owned_device(device_id, user, db)
    response = DeviceResponse.model_validate(device)
    return response.model_copy(
        update={"online": await presence_manager.is_online(device.id)}
    )


@router.post(
    "/{device_id}/challenge",
    response_model=DeviceChallengeResponse,
)
async def challenge_device(
    device_id: UUID,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> DeviceChallengeResponse:
    device = await owned_device(device_id, user, db)
    if device.revoked_at is not None:
        raise HTTPException(status_code=403, detail="Device is revoked")
    await enforce_rate_limit(
        "device-challenge",
        str(device.id),
        limit=get_settings().device_challenge_limit_per_minute,
    )
    challenge, expires_at = await create_device_challenge(device.id)
    return DeviceChallengeResponse(
        challenge=challenge,
        expires_at=expires_at,
    )


@router.post(
    "/{device_id}/verify",
    response_model=DeviceVerificationResponse,
)
async def verify_device(
    device_id: UUID,
    body: DeviceVerifyRequest,
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> DeviceVerificationResponse:
    device = await owned_device(device_id, user, db)
    if device.revoked_at is not None:
        raise HTTPException(status_code=403, detail="Device is revoked")
    verified = await verify_device_challenge(
        device.id,
        device.public_key,
        body.signature,
    )
    if not verified:
        raise HTTPException(
            status_code=401,
            detail="Invalid or expired device challenge",
        )

    device.verified_at = datetime.now(UTC)
    await db.commit()
    await db.refresh(device)
    device_token, expires_in = create_device_token(user.id, device.id)
    return DeviceVerificationResponse(
        device=DeviceResponse.model_validate(device),
        device_token=device_token,
        expires_in=expires_in,
    )


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
    await publish_device_event(
        device.id,
        make_event(
            "device.revoked",
            payload={"device_id": str(device.id)},
        ),
    )
    await presence_manager.disconnect_device(device.id, code=4003)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
