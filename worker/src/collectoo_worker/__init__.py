"""Collectoo worker service."""

from __future__ import annotations

import argparse
import logging
import os
import sys

__version__ = "0.1.0"


def main(argv: list[str] | None = None) -> int:
    """`collectoo-worker consume boarding`: run a queue consumer until stopped."""
    from collectoo_worker.jobs.boarding import make_handler  # noqa: PLC0415 - fast --help
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
    if args.cmd == "consume":
        QueueConsumer(os.environ["DATABASE_URL"], args.queue, make_handler(storage)).run_forever()
    return 0
