"""The M2c rule packs load as data (ADR-0005, design §8.5): no float anywhere, no unknown key, every
text cited with its version and a verbatim quote (a convention that is not law: a note, no quote),
no two VAT rows of a rate overlapping."""

from pathlib import Path
from typing import Any

import pytest
import yaml
from pydantic import ValidationError

from collectoo_worker.remittance.packs import (
    RULE_PACKS,
    LegalRef,
    RemittancePack,
    VatPack,
    load_yaml,
    remittance_pack,
    vat_pack,
)


def _raw(name: str) -> dict[str, Any]:
    data = yaml.safe_load((RULE_PACKS / name).read_text(encoding="utf-8"))
    assert isinstance(data, dict)
    return data


def test_the_packs_load() -> None:
    vat, rem = vat_pack(), remittance_pack()
    assert (vat.pack, rem.pack) == ("vat/fr", "remittance/fr")
    assert rem.deadline.months == 1 and rem.deadline.weekend_holiday_extension is False
    assert rem.schedule.twice_monthly_days == [1, 16]  # founder #1
    assert {c.id for c in rem.calendar.closing_days} >= {
        "easter_monday",
        "armistice",
        "good_friday",
    }
    refs = [*rem.deadline.legal_refs, *rem.calendar.legal_refs]
    assert {r.title.split(" (")[0] for r in refs} >= {
        "CPCE art. R124-6 al. 2",
        "CPC art. 641 al. 2",
        "CMF art. L133-13 I",
        "C. trav. art. L3133-1",
    }
    assert all(r.quote for r in refs if r.url) and all(
        r.note and not r.quote for r in refs if not r.url
    )


def test_a_float_is_refused(tmp_path: Path) -> None:
    raw = _raw("vat/fr.yaml")
    raw["rates"][0]["rate"] = 0.2
    (tmp_path / "x.yaml").write_text(yaml.safe_dump(raw, allow_unicode=True), encoding="utf-8")
    with pytest.raises(ValueError, match="float"):
        load_yaml(tmp_path / "x.yaml")


def test_unknown_keys_and_overlaps_are_refused() -> None:
    raw = _raw("vat/fr.yaml")
    with pytest.raises(ValidationError):
        VatPack.model_validate({**raw, "surprise": 1})
    overlapping = {
        **raw,
        "rates": [raw["rates"][0], {**raw["rates"][1], "valid_from": "2026-06-01"}],
    }
    with pytest.raises(ValidationError, match="overlap"):
        VatPack.model_validate(overlapping)
    with pytest.raises(ValidationError):
        VatPack.model_validate({**raw, "rates": [{**raw["rates"][0], "rate": "0.12345"}]})
    rem = _raw("remittance/fr.yaml")
    with pytest.raises(ValidationError):
        RemittancePack.model_validate({**rem, "deadline": {**rem["deadline"], "months": 2}})
    bad_day = {"id": "x", "month": 2, "day": 30, "label_fr": "X", "sources": ["target"]}
    cal = {**rem["calendar"], "closing_days": [*rem["calendar"]["closing_days"], bad_day]}
    with pytest.raises(ValidationError):
        RemittancePack.model_validate({**rem, "calendar": cal})


def test_a_text_is_quoted_or_noted() -> None:
    url = "https://librejustice.fr/norm/fr/code-civil/1993"
    LegalRef(title="C. civ. 1993", url=url, version="v", quote="Tout mandataire …")
    LegalRef(title="TARGET", note="not law")
    with pytest.raises(ValidationError, match="quote"):
        LegalRef(title="C. civ. 1993", url=url, version="v")
    with pytest.raises(ValidationError, match="LibreJustice"):
        LegalRef(title="X", url="https://example.com/x", version="v", quote="q")
    with pytest.raises(ValidationError, match="note"):
        LegalRef(title="TARGET")


def test_a_text_not_yet_in_force_awaits_its_review() -> None:
    """Every text applying after the day the pack was read carries a review due before it applies,
    and the reviews due the same day are recorded together (the rate row's, in public.vat_rate,
    then attests all of them)."""
    raw = _raw("vat/fr.yaml")
    refs = raw["references"]
    text = next(t for r in refs for t in r["texts"] if t["title"] == "CIBS art. L214-6")
    for bad in (
        {k: v for k, v in text.items() if k != "review"},
        {**text, "review": {**text["review"], "due_from": "2027-01-01"}},
    ):
        changed = [{**r, "texts": [bad if t is text else t for t in r["texts"]]} for r in refs]
        with pytest.raises(ValidationError, match="needs a review before"):
            VatPack.model_validate({**raw, "references": changed})
    apart = {**text, "review": {**text["review"], "reviewed_on": "2026-11-20", "reviewed_by": "X"}}
    changed = [{**r, "texts": [apart if t is text else t for t in r["texts"]]} for r in refs]
    with pytest.raises(ValidationError, match="recorded together"):
        VatPack.model_validate({**raw, "references": changed})
