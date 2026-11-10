"""Shared helpers for integration tests (need `make up`)."""

import hashlib
import json
import os
import uuid
from pathlib import Path
from typing import Any

import psycopg

from collectoo_worker.ai.mock import MockProvider
from collectoo_worker.jobs.boarding import make_handler
from collectoo_worker.runtime.queue import QueueConsumer
from collectoo_worker.runtime.storage import SupabaseStorage

DB = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")
CUT_OFF = "2026-09-30"  # sellers always stop the portfolio at a cut-off date (founder, 2026-11-08)


def storage() -> SupabaseStorage:
    return SupabaseStorage(
        os.environ.get("SUPABASE_URL", "http://127.0.0.1:54321"), os.environ["SUPABASE_SECRET_KEY"]
    )


def one(conn: psycopg.Connection[Any], sql: str, params: tuple[Any, ...] = ()) -> Any:
    row = conn.execute(sql, params).fetchone()
    assert row is not None
    return row[0]


def make_tenant() -> dict[str, Any]:
    with psycopg.connect(DB) as conn, conn.transaction():
        servicer = one(
            conn,
            "insert into public.organization (kind, legal_name)"
            " values ('servicer', 'S') returning id",
        )
        client = one(
            conn,
            "insert into public.organization (kind, servicer_organization_id, legal_name)"
            " values ('creditor_client', %s, 'C') returning id",
            (servicer,),
        )
        portfolio = one(
            conn,
            "insert into public.portfolio (organization_id, client_organization_id, name)"
            " values (%s, %s, 'P') returning id",
            (servicer, client),
        )
        user = uuid.uuid4()
        conn.execute(
            "insert into auth.users (id, email, aud, role)"
            " values (%s, %s, 'authenticated', 'authenticated')",
            (user, f"{user}@c.test"),
        )
        conn.execute(
            "insert into public.membership (user_id, organization_id, role)"
            " values (%s, %s, 'client_admin')",
            (user, client),
        )
        staff = uuid.uuid4()
        conn.execute(
            "insert into auth.users (id, email, aud, role)"
            " values (%s, %s, 'authenticated', 'authenticated')",
            (staff, f"{staff}@s.test"),
        )
        conn.execute(
            "insert into public.membership (user_id, organization_id, role)"
            " values (%s, %s, 'ops_manager')",
            (staff, servicer),
        )
    return {
        "servicer": servicer,
        "client": client,
        "portfolio": portfolio,
        "user": str(user),
        "staff": str(staff),
    }


def as_user(conn: psycopg.Connection[Any], user: str, aal: str = "aal1") -> None:
    claims = json.dumps({"sub": user, "role": "authenticated", "aal": aal})
    conn.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
    conn.execute("set local role authenticated")


def board(tenant: dict[str, Any], storage: SupabaseStorage, *paths: Path) -> str:
    """Create a batch, upload the files and submit, as the client admin (through the commands)."""
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        batch = one(
            conn,
            "select public.create_boarding_batch(%s, %s, %s)",
            (str(uuid.uuid4()), tenant["portfolio"], CUT_OFF),
        )
        regs = []
        for path in paths:
            data = path.read_bytes()
            reg = one(
                conn,
                "select public.add_boarding_file(%s, %s, %s, %s)",
                (batch, path.name, hashlib.sha256(data).hexdigest(), len(data)),
            )
            regs.append((reg["storage_path"], data))
    for storage_path, data in regs:
        storage.upload("boarding-uploads", storage_path, data, "application/octet-stream")
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.submit_boarding_batch(%s)", (batch,))
    return str(batch)


def drain(storage: SupabaseStorage) -> None:
    consumer = QueueConsumer(DB, "boarding", make_handler(storage, MockProvider()))
    while consumer.poll_once():
        pass


SCHEDULE = {  # commission-1: 15 % on everything allocated (synthetic)
    "schema": "commission-1",
    "basis": {
        "families": "all",
        "forwards": {
            "file_recalled": False,
            "before_servicing_start": False,
            "client_ratification": False,
        },
        "on_reversal": "credit",
    },
    "rules": [
        {
            "id": "tout",
            "tier_key": "tout",
            "label_fr": "Toutes créances",
            "match": {},
            "rate": {"kind": "flat", "rate": "0.15"},
        }
    ],
}
TERMS = {
    "schema": "remittance-1",
    "frequency": "twice_monthly",
    "netting": {"clause_ref": "art. 7.2"},
    "clawback": None,
    "invoice_payment_days": 30,
}


def ready_mandate(
    conn: psycopg.Connection[Any],
    tenant: dict[str, Any],
    reference: str,
    signed_on: str = "2026-01-01",
) -> str:
    """An active client mandate on the tenant's portfolio with what confirmation needs (R124-3;
    M2c-2, design §9.1): its version's commission schedule, remittance terms, clause references
    (2°, 3°, 4°) and signed document, and both billing identities (the servicer's complete, the
    client a professional established in mainland France). Synthetic identifiers."""
    servicer, client = tenant["servicer"], tenant["client"]
    conn.execute(
        "update public.organization set siren = case when id = %s then '732829320' else '552100554'"
        " end where id in (%s, %s) and siren is null",
        (servicer, servicer, client),
    )
    conn.execute(
        "insert into public.billing_identity (organization_id, legal_form, share_capital_minor,"
        " rcs_city, registered_office, vat_number, is_professional)"
        " select o.id, case when o.kind = 'servicer' then 'SAS' end,"
        "        case when o.kind = 'servicer' then 1000000 end,"
        "        case when o.kind = 'servicer' then 'Paris' end,"
        '        \'{"line1": "1 rue de la Paix", "postcode": "75002", "city": "Paris",'
        ' "country": "FR"}\','
        "        case when o.kind = 'servicer' then 'FR'"
        "          || lpad(((12 + 3 * (o.siren::bigint %% 97)) %% 97)::text, 2, '0')"
        "          || o.siren end,"
        "        true"
        " from public.organization o where o.id in (%s, %s)"
        " on conflict (organization_id) do nothing",
        (servicer, client),
    )
    doc = one(
        conn,
        "insert into public.document (organization_id, client_organization_id, kind, storage_path,"
        " sha256, mime_type) values (%s, %s, 'mandate_document', %s, %s, 'application/pdf')"
        " returning id",
        (servicer, client, f"client/test/{uuid.uuid4()}.pdf", "a" * 64),
    )
    mandate = one(
        conn,
        "insert into public.mandate (organization_id, client_organization_id, reference,"
        " mandate_type, signed_on, insurance_clause_ref)"
        " values (%s, %s, %s, 'mandate_amicable', %s, 'art. 9') returning id",
        (servicer, client, reference, signed_on),
    )
    conn.execute(
        "insert into public.mandate_terms (mandate_id, valid_from, commission_schedule,"
        " commission_clause_ref, remittance_terms, remittance_clause_ref, document_id)"
        " values (%s, %s, %s, 'art. 6', %s, 'art. 7', %s)",
        (mandate, signed_on, json.dumps(SCHEDULE), json.dumps(TERMS), doc),
    )
    conn.execute(
        "update public.portfolio set mandate_id = %s where id = %s",
        (mandate, tenant["portfolio"]),
    )
    return str(mandate)
