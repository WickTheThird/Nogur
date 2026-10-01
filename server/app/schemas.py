from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=1024)


class LoginRequest(RegisterRequest):
    pass


class RefreshRequest(BaseModel):
    refresh_token: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: Literal["bearer"] = "bearer"
    expires_in: int


class DeviceRegisterRequest(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    platform: str = Field(min_length=1, max_length=64)
    public_key: str = Field(min_length=1, max_length=16_384)


class DeviceResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    user_id: UUID
    name: str
    platform: str
    public_key: str
    created_at: datetime
    last_seen_at: datetime | None
    verified_at: datetime | None
    revoked_at: datetime | None
    online: bool = False


class DeviceChallengeResponse(BaseModel):
    challenge: str
    expires_at: datetime


class DeviceVerifyRequest(BaseModel):
    signature: str = Field(min_length=1, max_length=1024)


class DeviceVerificationResponse(BaseModel):
    device: DeviceResponse
    device_token: str
    expires_in: int


SessionCapability = Literal[
    "screen.view",
    "input.pointer",
    "input.keyboard",
    "input.scroll",
    "clipboard.read",
    "clipboard.write",
]

SessionStatus = Literal[
    "pending",
    "accepted",
    "connecting",
    "active",
    "rejected",
    "expired",
    "failed",
    "ended",
]


class CaptureRequest(BaseModel):
    type: Literal["display"] = "display"
    preferred_width: int = Field(default=1920, ge=320, le=7680)
    preferred_height: int = Field(default=1080, ge=240, le=4320)
    preferred_fps: int = Field(default=30, ge=1, le=60)


class SessionCreateRequest(BaseModel):
    target_device_id: UUID
    requested_capabilities: list[SessionCapability] = Field(min_length=1, max_length=6)
    capture: CaptureRequest = Field(default_factory=CaptureRequest)


class SessionAcceptRequest(BaseModel):
    approved_capabilities: list[SessionCapability] = Field(min_length=1, max_length=6)


class SessionEndRequest(BaseModel):
    reason: str = Field(default="ended_by_user", min_length=1, max_length=200)


class SessionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    user_id: UUID
    source_device_id: UUID
    target_device_id: UUID
    status: SessionStatus
    requested_capabilities: list[SessionCapability]
    approved_capabilities: list[SessionCapability]
    capture: dict[str, Any]
    created_at: datetime
    expires_at: datetime
    accepted_at: datetime | None
    connected_at: datetime | None
    ended_at: datetime | None
    end_reason: str | None
    source_ip: str | None
    target_ip: str | None


class RealtimeTicketResponse(BaseModel):
    ticket: str
    expires_at: datetime


class SignalingEnvelope(BaseModel):
    version: Literal[1] = 1
    event_id: UUID
    type: str = Field(min_length=1, max_length=100)
    session_id: UUID | None = None
    sent_at: datetime
    payload: dict[str, Any] = Field(default_factory=dict)


class IceServer(BaseModel):
    urls: list[str]
    username: str | None = None
    credential: str | None = None


class SessionTransportResponse(BaseModel):
    expires_at: datetime
    ice_servers: list[IceServer]


class SessionEventResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    session_id: UUID
    actor_device_id: UUID | None
    event_type: str
    payload: dict[str, Any]
    created_at: datetime
