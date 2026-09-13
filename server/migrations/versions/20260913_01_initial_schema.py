"""Create users, devices, and sessions.

Revision ID: 20260913_01
Revises:
Create Date: 2026-09-13
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "20260913_01"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("email", sa.String(length=320), nullable=False),
        sa.Column("password_hash", sa.Text(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_users_email", "users", ["email"], unique=True)

    op.create_table(
        "devices",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("platform", sa.String(length=64), nullable=False),
        sa.Column("public_key", sa.Text(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("public_key"),
    )
    op.create_index("ix_devices_user_id", "devices", ["user_id"])

    op.create_table(
        "sessions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("source_device_id", sa.Uuid(), nullable=False),
        sa.Column("target_device_id", sa.Uuid(), nullable=False),
        sa.Column("status", sa.String(length=20), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "source_device_id <> target_device_id",
            name="ck_sessions_distinct_devices",
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'accepted', 'rejected', 'ended')",
            name="ck_sessions_status",
        ),
        sa.ForeignKeyConstraint(
            ["source_device_id"], ["devices.id"], ondelete="RESTRICT"
        ),
        sa.ForeignKeyConstraint(
            ["target_device_id"], ["devices.id"], ondelete="RESTRICT"
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_sessions_source_device_id", "sessions", ["source_device_id"])
    op.create_index("ix_sessions_target_device_id", "sessions", ["target_device_id"])
    op.create_index("ix_sessions_user_id", "sessions", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_sessions_user_id", table_name="sessions")
    op.drop_index("ix_sessions_target_device_id", table_name="sessions")
    op.drop_index("ix_sessions_source_device_id", table_name="sessions")
    op.drop_table("sessions")
    op.drop_index("ix_devices_user_id", table_name="devices")
    op.drop_table("devices")
    op.drop_index("ix_users_email", table_name="users")
    op.drop_table("users")
