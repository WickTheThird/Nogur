from datetime import UTC, datetime, timedelta
from typing import Literal
from uuid import UUID, uuid4

import jwt
from pwdlib import PasswordHash
from pydantic import BaseModel, ValidationError

from app.config import get_settings

password_hash = PasswordHash.recommended()


class InvalidTokenError(Exception):
    pass


class TokenPayload(BaseModel):
    sub: UUID
    type: Literal["access", "refresh"]
    exp: datetime
    iat: datetime
    jti: UUID


class DeviceTokenPayload(BaseModel):
    sub: UUID
    device_id: UUID
    type: Literal["device"]
    exp: datetime
    iat: datetime
    jti: UUID


def hash_password(password: str) -> str:
    return password_hash.hash(password)


def verify_password(password: str, encoded_hash: str) -> bool:
    return password_hash.verify(password, encoded_hash)


def create_token(user_id: UUID, token_type: Literal["access", "refresh"]) -> str:
    settings = get_settings()
    now = datetime.now(UTC)
    lifetime = (
        timedelta(minutes=settings.access_token_expire_minutes)
        if token_type == "access"
        else timedelta(days=settings.refresh_token_expire_days)
    )
    payload = {
        "sub": str(user_id),
        "type": token_type,
        "iat": now,
        "exp": now + lifetime,
        "jti": str(uuid4()),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def decode_token(
    token: str, expected_type: Literal["access", "refresh"]
) -> TokenPayload:
    settings = get_settings()
    try:
        payload = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
        )
        parsed = TokenPayload.model_validate(payload)
    except (jwt.InvalidTokenError, ValidationError) as exc:
        raise InvalidTokenError from exc
    if parsed.type != expected_type:
        raise InvalidTokenError
    return parsed


def create_token_pair(user_id: UUID) -> tuple[str, str, int]:
    settings = get_settings()
    return (
        create_token(user_id, "access"),
        create_token(user_id, "refresh"),
        settings.access_token_expire_minutes * 60,
    )


def create_device_token(user_id: UUID, device_id: UUID) -> tuple[str, int]:
    settings = get_settings()
    now = datetime.now(UTC)
    lifetime = timedelta(days=settings.device_token_expire_days)
    payload = {
        "sub": str(user_id),
        "device_id": str(device_id),
        "type": "device",
        "iat": now,
        "exp": now + lifetime,
        "jti": str(uuid4()),
    }
    token = jwt.encode(
        payload,
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )
    return token, int(lifetime.total_seconds())


def decode_device_token(token: str) -> DeviceTokenPayload:
    settings = get_settings()
    try:
        payload = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
        )
        parsed = DeviceTokenPayload.model_validate(payload)
    except (jwt.InvalidTokenError, ValidationError) as exc:
        raise InvalidTokenError from exc
    return parsed
