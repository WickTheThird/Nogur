from fastapi import APIRouter

from app.api.routes import auth, devices, health, sessions, websocket

api_router = APIRouter()
api_router.include_router(auth.router)
api_router.include_router(devices.router)
api_router.include_router(health.router)
api_router.include_router(sessions.router)
api_router.include_router(websocket.router)
