"""Expand remote sessions for WebRTC signaling.

Revision ID: 20261001_02
Revises: 20260913_01
Create Date: 2026-10-01
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20261001_02"
down_revision: str | None = "20260913_01"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_constraint("ck_sessions_status", "sessions", type_="check")
    op.add_column(
        "sessions",
        sa.Column(
            "requested_capabilities",
            sa.JSON(),
            server_default=sa.text("'[]'"),
            nullable=False,
        ),
    )
    op.add_column(
        "sessions",
        sa.Column(
            "approved_capabilities",
            sa.JSON(),
            server_default=sa.text("'[]'"),
            nullable=False,
        ),
    )
    op.add_column(
        "sessions",
        sa.Column(
            "capture",
            sa.JSON(),
            server_default=sa.text("'{}'"),
            nullable=False,
        ),
    )
    op.add_column(
        "sessions",
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "sessions",
        sa.Column("connected_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "sessions", sa.Column("end_reason", sa.String(length=200), nullable=True)
    )
    op.add_column(
        "sessions", sa.Column("source_ip", sa.String(length=45), nullable=True)
    )
    op.add_column(
        "sessions", sa.Column("target_ip", sa.String(length=45), nullable=True)
    )
    op.execute(
        "UPDATE sessions SET expires_at = created_at + INTERVAL '2 minutes' "
        "WHERE expires_at IS NULL"
    )
    op.alter_column("sessions", "expires_at", nullable=False)
    op.create_check_constraint(
        "ck_sessions_status",
        "sessions",
        "status IN ('pending', 'accepted', 'connecting', 'active', "
        "'rejected', 'expired', 'failed', 'ended')",
    )
    op.create_index("ix_sessions_status", "sessions", ["status"])


def downgrade() -> None:
    op.drop_index("ix_sessions_status", table_name="sessions")
    op.drop_constraint("ck_sessions_status", "sessions", type_="check")
    op.execute(
        "UPDATE sessions SET status = 'ended', "
        "ended_at = COALESCE(ended_at, now()) "
        "WHERE status IN ('connecting', 'active', 'expired', 'failed')"
    )
    op.create_check_constraint(
        "ck_sessions_status",
        "sessions",
        "status IN ('pending', 'accepted', 'rejected', 'ended')",
    )
    op.drop_column("sessions", "target_ip")
    op.drop_column("sessions", "source_ip")
    op.drop_column("sessions", "end_reason")
    op.drop_column("sessions", "connected_at")
    op.drop_column("sessions", "expires_at")
    op.drop_column("sessions", "capture")
    op.drop_column("sessions", "approved_capabilities")
    op.drop_column("sessions", "requested_capabilities")
