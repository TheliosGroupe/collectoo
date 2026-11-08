"""M1-20 bulk documents: link by the reference in the file name (unit and integration)."""

import csv
import io
import json
import zipfile
from pathlib import Path
from typing import Any

import httpx
import psycopg
import pytest

from collectoo_worker.boarding.documents import find_reference, read_zip

PDF = b"%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n"


def make_zip(path: Path, refs: list[str]) -> Path:
    patterns = [
        "{r}.pdf",
        "facture_{r}_2026.pdf",
        "{r} - relance.pdf",
        "Scan {r}.PDF",
        "contrat-{r}.jpg",
    ]
    with zipfile.ZipFile(path, "w") as zf:
        for i, ref in enumerate(refs[:99]):
            zf.writestr(f"docs/{patterns[i % len(patterns)].format(r=ref)}", PDF)
        zf.writestr("docs/inconnu_ZZ9999.pdf", PDF)
        zf.writestr("docs/notes.docx", b"not supported")
        zf.writestr("__MACOSX/.DS_Store", b"")
    return path


def test_find_reference_prefers_whole_tokens_and_longest_match() -> None:
    refs = {"C1042", "C10420", "BAIL-104"}
    assert find_reference("facture_C10420_mars.pdf", refs) == "C10420"
    assert find_reference("BAIL-104 quittance.pdf", refs) == "BAIL-104"
    assert find_reference("scan0001.pdf", refs) is None


def test_zip_links_99_percent_and_lists_the_rest(tmp_path: Path) -> None:
    refs = [f"C{1000 + i}" for i in range(120)]
    result = read_zip(make_zip(tmp_path / "docs.zip", refs), set(refs))
    assert len(result.matched) == 99
    assert result.unmatched == ["inconnu_ZZ9999.pdf"]
    assert result.unsupported == ["notes.docx"]
    assert {m.mime for m in result.matched} == {"application/pdf", "image/jpeg"}


@pytest.mark.integration
def test_documents_are_linked_after_commit(tmp_path: Path) -> None:
    from integration_helpers import DB, as_user, board, drain, make_tenant, one, storage  # noqa: PLC0415

    from collectoo_worker.synth.civil import generate_civil  # noqa: PLC0415

    tenant: dict[str, Any] = make_tenant()
    table, _ = generate_civil("b2b_invoice", "fr_semicolon", 150, 29, defect_rate=0)
    tape = tmp_path / "factures.csv"
    buf = io.StringIO()
    csv.writer(buf, delimiter=";").writerows(table)
    tape.write_text(buf.getvalue(), encoding="utf-8")
    refs = sorted({r[0] for r in table[1:]})
    archive = make_zip(tmp_path / "pieces.zip", refs)
    store = storage()
    batch = board(tenant, store, tape, archive)
    drain(store)
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.approve_mapping(%s, %s)", (batch, json.dumps({})))
    drain(store)
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.commit_boarding_batch(%s)", (batch,))
    drain(store)
    with psycopg.connect(DB) as conn:
        linked = one(
            conn,
            "select count(*) from public.document d join public.account a on a.id = d.account_id"
            " where a.boarding_batch_id = %s",
            (batch,),
        )
        report = one(
            conn,
            "select dq_report -> 'documents' from public.boarding_batch where id = %s",
            (batch,),
        )
    expected = min(99, len(refs))
    assert linked == expected and report["linked"] == expected
    assert "inconnu_ZZ9999.pdf" in report["unmatched"]

    # Rollback removes the index rows at once and the files through the queue.
    with psycopg.connect(DB) as conn:
        paths = [
            r[0]
            for r in conn.execute(
                "select storage_path from public.document where boarding_batch_id = %s", (batch,)
            ).fetchall()
        ]
    store.download("documents", paths[0], tmp_path / "before.pdf")
    with psycopg.connect(DB) as conn, conn.transaction():
        as_user(conn, tenant["user"])
        conn.execute("select public.rollback_boarding_batch(%s, %s)", (batch, "wrong client"))
    with psycopg.connect(DB) as conn:
        left = one(
            conn, "select count(*) from public.document where boarding_batch_id = %s", (batch,)
        )
    assert left == 0
    drain(store)
    with pytest.raises(httpx.HTTPStatusError):
        store.download("documents", paths[0], tmp_path / "after.pdf")
