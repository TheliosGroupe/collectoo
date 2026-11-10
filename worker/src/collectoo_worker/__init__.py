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
    """`collectoo-worker consume boarding payments remittances`: run the consumers until stopped."""
    from collectoo_worker.jobs import boarding, payments, remittances  # noqa: PLC0415 - fast --help
    from collectoo_worker.runtime.queue import (  # noqa: PLC0415
        QueueConsumer,
        json_log_formatter,
        run_all,
    )
    from collectoo_worker.runtime.storage import SupabaseStorage  # noqa: PLC0415

    parser = argparse.ArgumentParser(prog="collectoo-worker")
    sub = parser.add_subparsers(dest="cmd", required=True)
    consume = sub.add_parser("consume", help="consume one or more queues")
    consume.add_argument("queues", nargs="+", choices=["boarding", "payments", "remittances"])
    args = parser.parse_args(argv)

    handler_ = logging.StreamHandler(sys.stdout)
    handler_.setFormatter(json_log_formatter())
    logging.basicConfig(level=logging.INFO, handlers=[handler_])

    storage = SupabaseStorage(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SECRET_KEY"])
    db = os.environ["DATABASE_URL"]
    consumers = []
    for queue in dict.fromkeys(args.queues):
        if queue == "boarding":
            provider = _provider(os.environ.get("LLM_PROVIDER", "mock"))
            addresses = _normaliser(os.environ.get("ADDRESS_NORMALISER", "mock"))
            handler = boarding.make_handler(storage, provider, addresses)
            consumers.append(QueueConsumer(db, queue, handler, on_dead=boarding.record_dead_job))
        elif queue == "remittances":
            consumers.append(
                QueueConsumer(
                    db,
                    queue,
                    remittances.make_handler(storage),
                    on_dead=remittances.record_dead_job,
                )
            )
        else:
            handler = payments.make_handler(storage)
            consumers.append(QueueConsumer(db, queue, handler, on_dead=payments.record_dead_job))
    run_all(consumers)
    return 0
