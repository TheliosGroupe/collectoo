"""Boarding queue jobs.

- `profile`: read every uploaded file of a batch, store its profile, queue `propose`.
- `propose`: propose a mapping per file (saved mapping profile if the layout is known,
  otherwise the LLM gateway), store it for review, propose join keys across files.
- `transform` (queued when the mapping is approved): transform and validate every file, assign
  claim types and legal regimes, normalise addresses, store issues and the data-quality report;
  the batch ends `validated` or `needs_fix`.
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any

import polars as pl
import psycopg
from psycopg.types.json import Jsonb

from collectoo_worker.ai.gateway import Gateway, Provider
from collectoo_worker.boarding import assign
from collectoo_worker.boarding.address import MockNormaliser, Normaliser, normalise_cached
from collectoo_worker.boarding.dq import build_report
from collectoo_worker.boarding.mapping import (
    Proposal,
    from_saved_profile,
    header_signature,
    join_keys,
    propose,
)
from collectoo_worker.boarding.profile import profile_frame
from collectoo_worker.boarding.readers import read_xlsx, scan_csv
from collectoo_worker.boarding.transforms import load_spec
from collectoo_worker.boarding.validate import FileResult, detect_eba_table, rules, validate_batch
from collectoo_worker.runtime.storage import Storage

ACTOR = "worker:boarding"


def make_handler(storage: Storage, provider: Provider, normaliser: Normaliser | None = None) -> Any:
    addresses = normaliser or MockNormaliser()

    def handle(payload: dict[str, Any], conn: psycopg.Connection[Any]) -> None:
        kind = payload.get("type")
        batch_id = str(payload["batch_id"])
        if kind == "profile":
            profile_batch(conn, storage, batch_id)
        elif kind == "propose":
            propose_batch(conn, Gateway(provider, conn), batch_id)
        elif kind == "transform":
            transform_batch(conn, storage, addresses, batch_id)
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


def mappable_profile(profile: dict[str, Any]) -> dict[str, Any] | None:
    """The tabular profile to map: the file itself, or the first non-empty sheet of a workbook."""
    if "columns" in profile:
        return profile
    for sheet in profile.get("sheets", {}).values():
        if sheet["row_count"]:
            return dict(sheet)
    return None


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
        "select private.transition_batch(%s, 'profiled', 'profiling done', %s)", (batch_id, ACTOR)
    )
    # Same transaction: the next step is queued only if profiling committed.
    conn.execute(
        "select pgmq.send('boarding', %s)", (Jsonb({"type": "propose", "batch_id": batch_id}),)
    )


def propose_batch(conn: psycopg.Connection[Any], gateway: Gateway, batch_id: str) -> None:
    client_row = conn.execute(
        "select client_organization_id from public.boarding_batch where id = %s", (batch_id,)
    ).fetchone()
    if client_row is None:
        raise ValueError(f"unknown batch {batch_id}")
    files = conn.execute(
        "select id, profile from public.boarding_file where batch_id = %s order by created_at",
        (batch_id,),
    ).fetchall()
    by_file: dict[str, list[Proposal]] = {}
    for file_id, profile in files:
        table = mappable_profile(profile or {})
        if table is None:
            continue
        headers = [c["name"] for c in table["columns"]]
        saved = conn.execute(
            """select mapping, version from public.mapping_profile
               where client_organization_id = %s and header_signature = %s
               order by version desc limit 1""",
            (client_row[0], header_signature(headers)),
        ).fetchone()
        if saved:
            proposals = from_saved_profile(headers, saved[0], int(saved[1]))
        else:
            proposals = propose(gateway, table, batch_id=batch_id)
        by_file[str(file_id)] = proposals
        conn.execute(
            "delete from public.mapping_proposal where file_id = %s", (file_id,)
        )  # idempotent rerun
        rows = [
            {
                "batch_id": batch_id,
                "file_id": file_id,
                "source_column": p.source_column,
                "target": p.target,
                "confidence": round(p.confidence, 3),
                "rationale": p.rationale,
                "needs_review": p.needs_review,
                "origin": p.origin,
            }
            for p in proposals
        ]
        with conn.cursor() as cur:
            cur.executemany(
                """insert into public.mapping_proposal (batch_id, file_id, source_column, target,
                     confidence, rationale, needs_review, origin)
                   values (%(batch_id)s, %(file_id)s, %(source_column)s, %(target)s,
                     %(confidence)s, %(rationale)s, %(needs_review)s, %(origin)s)""",
                rows,
            )
    conn.execute(
        "update public.boarding_batch set join_keys = %s where id = %s",
        (Jsonb(join_keys(by_file)), batch_id),
    )
    conn.execute(
        "select private.transition_batch(%s, 'mapping_proposed', 'mapping proposed', %s)",
        (batch_id, ACTOR),
    )


def read_table(path: Path, file_format: str) -> pl.DataFrame | None:
    """All columns as text: a CSV, or the first non-empty sheet of a workbook."""
    if file_format == "csv":
        return scan_csv(path)[0].collect(engine="streaming")
    if file_format == "xlsx":
        return next((df for df in read_xlsx(path).values() if df.height), None)
    return None


def _address_stats(
    files: list[FileResult], normaliser: Normaliser, conn: psycopg.Connection[Any]
) -> dict[str, Any]:
    queries = []
    for f in files:
        lines, codes = f.values.get("contact.address_line"), f.values.get("contact.postcode")
        if lines is None:
            continue
        codes = codes or [None] * f.rows
        queries += [(str(line), codes[i]) for i, line in enumerate(lines) if line]
    if not queries:
        return {}
    results = normalise_cached(normaliser, queries, conn)
    ok = sum(r.normalised for r in results)
    return {"provider": normaliser.name, "addresses": len(results), "normalised": ok,
            "normalised_pct": round(ok / len(results), 4)}  # fmt: skip


def transform_batch(
    conn: psycopg.Connection[Any], storage: Storage, normaliser: Normaliser, batch_id: str
) -> None:
    batch = conn.execute(
        """select p.default_claim_type, b.conformance, b.art4_exemptions, b.seller_control_totals,
                  b.join_keys
           from public.boarding_batch b join public.portfolio p on p.id = b.portfolio_id
           where b.id = %s""",
        (batch_id,),
    ).fetchone()
    if batch is None:
        raise ValueError(f"unknown batch {batch_id}")
    default_type, conformance, art4, control, keys = batch
    files = conn.execute(
        """select id, file_name, storage_bucket, storage_path, format, profile
           from public.boarding_file where batch_id = %s order by created_at""",
        (batch_id,),
    ).fetchall()
    mapping_rows = conn.execute(
        "select file_id, source_column, target from public.mapping_proposal where batch_id = %s",
        (batch_id,),
    ).fetchall()
    mappings: dict[str, dict[str, str | None]] = {}
    for file_id, column, target in mapping_rows:
        mappings.setdefault(str(file_id), {})[column] = target

    results: list[FileResult] = []
    profiles: dict[str, dict[str, Any]] = {}
    with tempfile.TemporaryDirectory() as tmp:
        for file_id, name, bucket, path, file_format, profile in files:
            fid = str(file_id)
            if fid not in mappings:
                continue
            table = read_table(storage.download(bucket, path, Path(tmp) / fid), file_format)
            if table is None:
                continue
            mapping = mappings[fid]
            results.append(
                FileResult(fid, name, table, mapping, eba_table=detect_eba_table(mapping))
            )
            profiles[fid] = mappable_profile(profile or {}) or {}

    log = validate_batch(
        results,
        profiles,
        portfolio_default=default_type,
        conformance=conformance,
        art4_exempt=any(bool(v) for v in (art4 or {}).values()),
        join_keys=keys or [],
    )
    versions = {
        "transform": load_spec().version,
        "validation": int(rules()["version"]),
        "claim_types": int(assign.rules()["version"]),
    }
    report = build_report(
        results,
        log,
        control=control or {},
        spec_versions=versions,
        addresses=_address_stats(results, normaliser, conn),
    )

    conn.execute("delete from public.validation_issue where batch_id = %s", (batch_id,))
    with conn.cursor() as cur:
        cur.executemany(
            """insert into public.validation_issue (batch_id, file_id, row_number, source_column,
                 target, code, severity, message, raw_value)
               values (%s, %s, %s, %s, %s, %s, %s, %s, %s)""",
            [
                (
                    batch_id,
                    i.file_id,
                    i.row,
                    i.column,
                    i.target,
                    i.code,
                    i.severity,
                    i.message,
                    i.value,
                )
                for i in log.issues
            ],
        )
    conn.execute(
        """update public.boarding_batch
           set dq_report = %s, transform_spec_version = %s, validation_spec_version = %s,
               claim_type_spec_version = %s
           where id = %s""",
        (
            Jsonb(report),
            versions["transform"],
            versions["validation"],
            versions["claim_types"],
            batch_id,
        ),
    )
    conn.execute(
        "select private.transition_batch(%s, 'transformed', 'transformed', %s)", (batch_id, ACTOR)
    )
    outcome = "needs_fix" if log.blocking else "validated"
    reason = f"{log.blocking} blocking issue(s)" if log.blocking else "no blocking issue"
    conn.execute(
        "select private.transition_batch(%s, %s, %s, %s)", (batch_id, outcome, reason, ACTOR)
    )
