"""Boarding queue jobs. `profile`: read every uploaded file of a batch and store its profile."""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from collectoo_worker.boarding.profile import profile_frame
from collectoo_worker.boarding.readers import read_xlsx, scan_csv
from collectoo_worker.runtime.storage import Storage


def make_handler(storage: Storage) -> Any:
    def handle(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        kind = payload.get("type")
        if kind == "profile":
            profile_batch(conn, storage, str(payload["batch_id"]))
        else:
            raise ValueError(f"unknown boarding job type: {kind!r}")

    return handle


def profile_file(path: Path, file_format: str) -> tuple[dict[str, Any], int | None]:
    if file_format == "csv":
        lf, dialect = scan_csv(path)
        profile = profile_frame(lf)
        profile["csv"] = {"encoding": dialect.encoding, "separator": dialect.separator}
        return profile, int(profile["row_count"])
    if file_format == "xlsx":
        sheets = {name: profile_frame(df.lazy()) for name, df in read_xlsx(path).items()}
        return {"sheets": sheets}, sum(int(p["row_count"]) for p in sheets.values())
    if file_format == "fixed_width":
        return {"needs_layout": True}, None
    return {"not_profiled": file_format}, None  # zip: documents, handled in M1-20


def profile_batch(conn: psycopg.Connection[Any], storage: Storage, batch_id: str) -> None:
    files = conn.execute(
        """select id, storage_bucket, storage_path, format from public.boarding_file
           where batch_id = %s order by created_at""",
        (batch_id,),
    ).fetchall()
    with tempfile.TemporaryDirectory() as tmp:
        for file_id, bucket, path, file_format in files:
            local = storage.download(bucket, path, Path(tmp) / str(file_id))
            profile, rows = profile_file(local, file_format)
            conn.execute(
                """update public.boarding_file
                   set profile = %s, row_count = %s, status = 'profiled', error = null
                   where id = %s""",
                (Jsonb(profile), rows, file_id),
            )
    conn.execute(
        "select private.transition_batch(%s, 'profiled', 'profiling done', 'worker:boarding')",
        (batch_id,),
    )
