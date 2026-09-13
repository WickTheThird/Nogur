from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.models import User
from app.schemas import LoginRequest, RefreshRequest, RegisterRequest, TokenPair
from app.security import (
    InvalidTokenError,
    create_token_pair,
    decode_token,
    hash_password,
    verify_password,
)

router = APIRouter(prefix="/auth", tags=["auth"])


def token_response(user_id: UUID) -> TokenPair:
    access_token, refresh_token, expires_in = create_token_pair(user_id)
    return TokenPair(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=expires_in,
    )


@router.post("/register", response_model=TokenPair, status_code=201)
async def register(
    body: RegisterRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TokenPair:
    email = str(body.email).casefold()
    existing = await db.scalar(select(User.id).where(User.email == email))
    if existing is not None:
        raise HTTPException(status_code=409, detail="Email is already registered")

    user = User(email=email, password_hash=hash_password(body.password))
    db.add(user)
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(
            status_code=409, detail="Email is already registered"
        ) from None
    await db.refresh(user)
    return token_response(user.id)


@router.post("/login", response_model=TokenPair)
async def login(
    body: LoginRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TokenPair:
    user = await db.scalar(select(User).where(User.email == str(body.email).casefold()))
    if user is None or not verify_password(body.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid email or password")
    return token_response(user.id)


@router.post("/refresh", response_model=TokenPair)
async def refresh(
    body: RefreshRequest,
    db: Annotated[AsyncSession, Depends(get_db)],
) -> TokenPair:
    try:
        payload = decode_token(body.refresh_token, "refresh")
    except InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid refresh token") from None
    if await db.get(User, payload.sub) is None:
        raise HTTPException(status_code=401, detail="Invalid refresh token")
    return token_response(payload.sub)
