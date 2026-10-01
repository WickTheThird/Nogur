import uuid
from datetime import datetime

from sqlalchemy import (
    JSON,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class RemoteSession(Base):
    __tablename__ = "sessions"
    __table_args__ = (
        CheckConstraint(
            "status IN ('pending', 'accepted', 'connecting', 'active', "
            "'rejected', 'expired', 'failed', 'ended')",
            name="ck_sessions_status",
        ),
        CheckConstraint(
            "source_device_id <> target_device_id",
            name="ck_sessions_distinct_devices",
        ),
        Index("ix_sessions_user_id", "user_id"),
        Index("ix_sessions_source_device_id", "source_device_id"),
        Index("ix_sessions_target_device_id", "target_device_id"),
        Index("ix_sessions_status", "status"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE")
    )
    source_device_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("devices.id", ondelete="RESTRICT")
    )
    target_device_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("devices.id", ondelete="RESTRICT")
    )
    status: Mapped[str] = mapped_column(String(20), default="pending")
    requested_capabilities: Mapped[list[str]] = mapped_column(JSON, default=list)
    approved_capabilities: Mapped[list[str]] = mapped_column(JSON, default=list)
    capture: Mapped[dict[str, object]] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    connected_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    end_reason: Mapped[str | None] = mapped_column(String(200))
    source_ip: Mapped[str | None] = mapped_column(String(45))
    target_ip: Mapped[str | None] = mapped_column(String(45))
