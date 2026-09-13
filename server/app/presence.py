import json
from collections import defaultdict
from uuid import UUID, uuid4

from fastapi import WebSocket

from app.config import get_settings
from app.redis import get_redis


class PresenceManager:
    def __init__(self) -> None:
        self.instance_id = str(uuid4())
        self.connections: dict[UUID, set[WebSocket]] = defaultdict(set)

    def key(self, device_id: UUID) -> str:
        return f"nogur:presence:{device_id}"

    async def connect(self, device_id: UUID, user_id: UUID, socket: WebSocket) -> None:
        await socket.accept()
        self.connections[device_id].add(socket)
        await self.refresh(device_id, user_id)

    async def refresh(self, device_id: UUID, user_id: UUID) -> None:
        value = json.dumps({"instance_id": self.instance_id, "user_id": str(user_id)})
        await get_redis().set(
            self.key(device_id),
            value,
            ex=get_settings().presence_ttl_seconds,
        )

    async def disconnect(self, device_id: UUID, socket: WebSocket) -> None:
        sockets = self.connections.get(device_id)
        if sockets is None:
            return
        sockets.discard(socket)
        if sockets:
            return
        self.connections.pop(device_id, None)
        value = await get_redis().get(self.key(device_id))
        is_this_instance = (
            value is not None
            and json.loads(value).get("instance_id") == self.instance_id
        )
        if is_this_instance:
            await get_redis().delete(self.key(device_id))

    async def disconnect_device(self, device_id: UUID, code: int = 1000) -> None:
        sockets = list(self.connections.get(device_id, set()))
        for socket in sockets:
            await socket.close(code=code)
            await self.disconnect(device_id, socket)


presence_manager = PresenceManager()
