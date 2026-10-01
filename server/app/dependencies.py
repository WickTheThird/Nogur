from typing import Annotated
from uuid import UUID

from fastapi import Depends, Header, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.models import Device, User
from app.security import InvalidTokenError, decode_device_token, decode_token

bearer_scheme = HTTPBearer(auto_error=False)


async def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> User:
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or missing access token",
        headers={"WWW-Authenticate": "Bearer"},
    )
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise unauthorized
    try:
        payload = decode_token(credentials.credentials, "access")
    except InvalidTokenError:
        raise unauthorized from None
    user = await db.get(User, payload.sub)
    if user is None:
        raise unauthorized
    return user


async def get_current_device(
    device_id: Annotated[UUID, Header(alias="X-Device-ID")],
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
) -> Device:
    device = await db.get(Device, device_id)
    if device is None or device.user_id != user.id or device.revoked_at is not None:
        raise HTTPException(status_code=403, detail="Unknown or revoked device")
    return device


async def get_verified_current_device(
    device: Annotated[Device, Depends(get_current_device)],
    user: Annotated[User, Depends(get_current_user)],
    device_token: Annotated[str | None, Header(alias="X-Device-Token")] = None,
) -> Device:
    if device.verified_at is None or device_token is None:
        raise HTTPException(status_code=403, detail="Device is not verified")
    try:
        payload = decode_device_token(device_token)
    except InvalidTokenError:
        raise HTTPException(status_code=403, detail="Invalid device token") from None
    if payload.sub != user.id or payload.device_id != device.id:
        raise HTTPException(status_code=403, detail="Device token does not match")
    return device
