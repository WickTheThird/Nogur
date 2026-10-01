import base64
import json
import secrets
from datetime import UTC, datetime, timedelta
from uuid import UUID

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from app.config import get_settings
from app.redis import get_redis


class InvalidDeviceKeyError(ValueError):
    pass


def decode_base64(value: str) -> bytes:
    try:
        return base64.b64decode(value, validate=True)
    except ValueError as exc:
        raise InvalidDeviceKeyError from exc


def validate_public_key(value: str) -> None:
    raw = decode_base64(value)
    if len(raw) != 32:
        raise InvalidDeviceKeyError
    try:
        Ed25519PublicKey.from_public_bytes(raw)
    except ValueError as exc:
        raise InvalidDeviceKeyError from exc


def challenge_key(device_id: UUID) -> str:
    return f"nogur:device-challenge:{device_id}"


async def create_device_challenge(device_id: UUID) -> tuple[str, datetime]:
    settings = get_settings()
    challenge = secrets.token_bytes(32)
    encoded = base64.b64encode(challenge).decode()
    expires_at = datetime.now(UTC) + timedelta(
        seconds=settings.device_challenge_ttl_seconds
    )
    await get_redis().set(
        challenge_key(device_id),
        json.dumps({"challenge": encoded}),
        ex=settings.device_challenge_ttl_seconds,
    )
    return encoded, expires_at


async def verify_device_challenge(
    device_id: UUID,
    public_key: str,
    signature: str,
) -> bool:
    raw_challenge = await get_redis().getdel(challenge_key(device_id))
    if raw_challenge is None:
        return False
    try:
        challenge = decode_base64(json.loads(raw_challenge)["challenge"])
        raw_key = decode_base64(public_key)
        raw_signature = decode_base64(signature)
        Ed25519PublicKey.from_public_bytes(raw_key).verify(
            raw_signature,
            challenge,
        )
    except (
        InvalidDeviceKeyError,
        InvalidSignature,
        KeyError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
    ):
        return False
    return True
