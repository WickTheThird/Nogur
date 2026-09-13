from typing import Literal

from fastapi import APIRouter, Depends, Response, status
from pydantic import BaseModel
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.redis import get_redis

router = APIRouter(tags=["health"])


class ServiceHealth(BaseModel):
    status: Literal["ok", "error"]
    database: Literal["ok", "error"]
    redis: Literal["ok", "error"]


@router.get("/health", response_model=ServiceHealth)
async def health_check(
    response: Response,
    db: AsyncSession = Depends(get_db),
    redis: Redis = Depends(get_redis),
) -> ServiceHealth:
    database_status: Literal["ok", "error"] = "ok"
    redis_status: Literal["ok", "error"] = "ok"

    try:
        await db.execute(text("SELECT 1"))
    except Exception:
        database_status = "error"

    try:
        await redis.ping()
    except Exception:
        redis_status = "error"

    overall: Literal["ok", "error"] = (
        "ok" if database_status == redis_status == "ok" else "error"
    )
    if overall == "error":
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE

    return ServiceHealth(
        status=overall,
        database=database_status,
        redis=redis_status,
    )
