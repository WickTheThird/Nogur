import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (Index("ix_devices_user_id", "user_id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE")
    )
    name: Mapped[str] = mapped_column(String(120))
    platform: Mapped[str] = mapped_column(String(64))
    public_key: Mapped[str] = mapped_column(Text, unique=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
