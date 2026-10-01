from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.models import RemoteSession, SessionEvent


def record_session_event(
    db: AsyncSession,
    session: RemoteSession,
    event_type: str,
    *,
    actor_device_id: UUID | None = None,
    payload: dict[str, object] | None = None,
) -> None:
    db.add(
        SessionEvent(
            session_id=session.id,
            actor_device_id=actor_device_id,
            event_type=event_type,
            payload=payload or {},
        )
    )
