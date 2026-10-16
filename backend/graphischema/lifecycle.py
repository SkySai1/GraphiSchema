"""Frontend leases and idle shutdown coordination for the local backend."""

from __future__ import annotations

from collections.abc import Callable
from time import monotonic


KEEPALIVE_TIMEOUT_SECONDS = 60.0
IDLE_CHECK_INTERVAL_SECONDS = 1.0
RELEASE_GRACE_SECONDS = 1.0


class BackendLifecycle:
    def __init__(self) -> None:
        now = monotonic()
        self._leases: dict[str, float] = {}
        self._last_activity = now
        self._shutdown_deadline: float | None = None
        self._shutdown_requested = False

    def keepalive(self, client_id: str) -> int | None:
        if self._shutdown_requested:
            return None
        now = monotonic()
        self._leases[client_id] = now
        self._last_activity = now
        self._shutdown_deadline = None
        return len(self._leases)

    def release(self, client_id: str) -> tuple[int, bool]:
        self._leases.pop(client_id, None)
        if not self._leases and not self._shutdown_requested:
            self._shutdown_deadline = monotonic() + RELEASE_GRACE_SECONDS
        return len(self._leases), self._shutdown_deadline is not None

    def should_shutdown(self) -> bool:
        if self._shutdown_requested:
            return False

        now = monotonic()
        expired = [
            client_id
            for client_id, last_seen in self._leases.items()
            if now - last_seen >= KEEPALIVE_TIMEOUT_SECONDS
        ]
        for client_id in expired:
            self._leases.pop(client_id, None)

        if self._leases:
            self._shutdown_deadline = None
            return False

        if self._shutdown_deadline is None:
            self._shutdown_deadline = self._last_activity + KEEPALIVE_TIMEOUT_SECONDS + RELEASE_GRACE_SECONDS
        if now < self._shutdown_deadline:
            return False

        self._shutdown_requested = True
        return True


_server_shutdown_callback: Callable[[], None] | None = None


def set_server_shutdown_callback(callback: Callable[[], None]) -> None:
    """Install the Uvicorn server's graceful shutdown hook."""
    global _server_shutdown_callback
    _server_shutdown_callback = callback


def request_server_shutdown() -> None:
    callback = _server_shutdown_callback
    if callback is not None:
        callback()
