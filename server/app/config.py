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
    api_prefix: str = "/v1"
    database_url: str = Field(
        default="postgresql+asyncpg://postgres:postgres@localhost:5432/nogur"
    )
    redis_url: str = "redis://localhost:6379/0"
    jwt_secret: str = "development-only-secret-key-32-bytes"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: PositiveInt = 15
    refresh_token_expire_days: PositiveInt = 30
    presence_ttl_seconds: PositiveInt = 120
    websocket_ticket_ttl_seconds: PositiveInt = 30
    device_challenge_ttl_seconds: PositiveInt = 120
    device_token_expire_days: PositiveInt = 30
    device_challenge_limit_per_minute: PositiveInt = 10
    session_create_limit_per_minute: PositiveInt = 10
    ticket_create_limit_per_minute: PositiveInt = 60
    session_request_ttl_seconds: PositiveInt = 120
    stun_urls: str = "stun:stun.l.google.com:19302"
    turn_urls: str = ""
    turn_shared_secret: str = ""
    turn_credential_ttl_seconds: PositiveInt = 600


@lru_cache
def get_settings() -> Settings:
    return Settings()
