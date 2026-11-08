"""Collectoo worker service."""

from __future__ import annotations

import argparse
import logging
import os
import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collectoo_worker.ai.gateway import Provider
    from collectoo_worker.boarding.address import Normaliser

__version__ = "0.1.0"


def _provider(name: str) -> Provider:
    """Only the mock exists until a real LLM key is provided (BRIEF §5)."""
    from collectoo_worker.ai.mock import MockProvider  # noqa: PLC0415

    if name != "mock":
        raise SystemExit(f"LLM_PROVIDER={name!r} is not configured; only 'mock' is available")
    return MockProvider()


def _normaliser(name: str) -> Normaliser:
    """`mock` (default, CI) or `ban` (api-adresse.data.gouv.fr, must be allowed by the network)."""
    from collectoo_worker.boarding.address import BanNormaliser, MockNormaliser  # noqa: PLC0415

    return BanNormaliser() if name == "ban" else MockNormaliser()


def main(argv: list[str] | None = None) -> int:
    """`collectoo-worker consume boarding`: run a queue consumer until stopped."""
    from collectoo_worker.jobs.boarding import (  # noqa: PLC0415 - fast --help
        make_handler,
        record_dead_job,
    )
    from collectoo_worker.runtime.queue import QueueConsumer, json_log_formatter  # noqa: PLC0415
    from collectoo_worker.runtime.storage import SupabaseStorage  # noqa: PLC0415

    parser = argparse.ArgumentParser(prog="collectoo-worker")
    sub = parser.add_subparsers(dest="cmd", required=True)
    consume = sub.add_parser("consume", help="consume a queue")
    consume.add_argument("queue", choices=["boarding"])
    args = parser.parse_args(argv)

    handler_ = logging.StreamHandler(sys.stdout)
    handler_.setFormatter(json_log_formatter())
    logging.basicConfig(level=logging.INFO, handlers=[handler_])

    storage = SupabaseStorage(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SECRET_KEY"])
    provider = _provider(os.environ.get("LLM_PROVIDER", "mock"))
    addresses = _normaliser(os.environ.get("ADDRESS_NORMALISER", "mock"))
    if args.cmd == "consume":
        handler = make_handler(storage, provider, addresses)
        QueueConsumer(
            os.environ["DATABASE_URL"], args.queue, handler, on_dead=record_dead_job
        ).run_forever()
    return 0
