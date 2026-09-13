from datetime import datetime
from typing import Literal
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
    revoked_at: datetime | None


class SessionCreateRequest(BaseModel):
    target_device_id: UUID


class SessionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    user_id: UUID
    source_device_id: UUID
    target_device_id: UUID
    status: Literal["pending", "accepted", "rejected", "ended"]
    created_at: datetime
    accepted_at: datetime | None
    ended_at: datetime | None
