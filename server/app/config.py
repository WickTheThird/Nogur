from functools import lru_cache

from pydantic import Field, PositiveInt
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        env_prefix="NOGUR_",
        extra="ignore",
        case_sensitive=False,
    )

    app_name: str = "Nogur API"
    app_env: str = "development"
    debug: bool = False
    api_prefix: str = ""
    database_url: str = Field(
        default="postgresql+asyncpg://postgres:postgres@localhost:5432/nogur"
    )
    redis_url: str = "redis://localhost:6379/0"
    jwt_secret: str = "development-only-secret-key-32-bytes"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: PositiveInt = 15
    refresh_token_expire_days: PositiveInt = 30
    presence_ttl_seconds: PositiveInt = 120


@lru_cache
def get_settings() -> Settings:
    return Settings()
