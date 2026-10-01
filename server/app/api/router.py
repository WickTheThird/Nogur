from fastapi import APIRouter, Depends

from app.api.routes import auth, devices, health, realtime, sessions, websocket
from app.dependencies import get_current_user

api_router = APIRouter()
api_router.include_router(auth.router)
api_router.include_router(health.router)

# HTTP application routes are private by default. Route functions still request
# the current user when they need the User object; FastAPI reuses the resolved
# dependency within the request.
protected_router = APIRouter(dependencies=[Depends(get_current_user)])
protected_router.include_router(devices.router)
protected_router.include_router(realtime.router)
protected_router.include_router(sessions.router)
api_router.include_router(protected_router)

# WebSockets authenticate their bearer token and device header during the
# handshake because HTTPBearer is not suitable for this connection type.
api_router.include_router(websocket.router)
