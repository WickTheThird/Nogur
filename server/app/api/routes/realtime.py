from typing import Annotated

from fastapi import APIRouter, Depends

from app.config import get_settings
from app.dependencies import get_current_user, get_verified_current_device
from app.models import Device, User
from app.rate_limit import enforce_rate_limit
from app.realtime import create_websocket_ticket
from app.schemas import RealtimeTicketResponse

router = APIRouter(prefix="/realtime", tags=["realtime"])


@router.post("/tickets", response_model=RealtimeTicketResponse)
async def create_ticket(
    device: Annotated[Device, Depends(get_verified_current_device)],
    user: Annotated[User, Depends(get_current_user)],
) -> RealtimeTicketResponse:
    await enforce_rate_limit(
        "realtime-ticket",
        str(device.id),
        limit=get_settings().ticket_create_limit_per_minute,
    )
    ticket, expires_at = await create_websocket_ticket(user.id, device.id)
    return RealtimeTicketResponse(ticket=ticket, expires_at=expires_at)
