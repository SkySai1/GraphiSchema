"""Uvicorn entry point that allows the API lifespan to request shutdown."""

from __future__ import annotations

import argparse

import uvicorn

from . import api
from .lifecycle import set_server_shutdown_callback


def main() -> None:
    parser = argparse.ArgumentParser(description="GraphiSchema local API server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()

    server = uvicorn.Server(
        uvicorn.Config(
            api.app,
            host=args.host,
            port=args.port,
            log_level="warning",
            timeout_graceful_shutdown=10,
        )
    )
    set_server_shutdown_callback(lambda: setattr(server, "should_exit", True))
    server.run()


if __name__ == "__main__":
    main()
