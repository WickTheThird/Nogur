from fastapi import HTTPException

from app.redis import get_redis


async def enforce_rate_limit(
    scope: str,
    identifier: str,
    *,
    limit: int,
    window_seconds: int = 60,
) -> None:
    key = f"nogur:rate:{scope}:{identifier}"
    redis = get_redis()
    count = await redis.incr(key)
    if count == 1:
        await redis.expire(key, window_seconds)
    if count > limit:
        raise HTTPException(
            status_code=429,
            detail="Too many requests",
            headers={"Retry-After": str(window_seconds)},
        )
