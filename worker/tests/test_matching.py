"""Reconciliation rules R1-R6 (M2-08, design §8.4, founder decision #3): one test per rule and its
limits, and properties: a reference with one typo never matches automatically, a tie never does,
nor does an amount alone."""

import random
from collections.abc import Sequence
from dataclasses import replace
from datetime import date

from hypothesis import given, settings
from hypothesis import strategies as st

from collectoo_worker.payments.matching import (
    RULES,
    AccountInfo,
    Decision,
    Directory,
    ItemInfo,
    PaymentIn,
    Signals,
    is_lookup_token,
    match_all,
    name_words,
    read_signals,
    ref_key,
    shared_words,
    similarity,
)
from collectoo_worker.payments.reconciliation_eval import failures, run
from collectoo_worker.payments.rf import rf_format, rf_make, rf_valid
from collectoo_worker.synth.ids import iban_fr
from collectoo_worker.synth.reconciliation import (
    EXPECT,
    MIX,
    Credit,
    Score,
    generate_credits,
    synthetic_world,
)

DAY = date(2026, 10, 12)
RF_A = rf_make("482193057612")
RF_B = rf_make("730261884529")
IBAN_X = iban_fr(random.Random(1))
IBAN_Y = iban_fr(random.Random(2))


def account(  # noqa: PLR0913 - a file as the tests need it
    aid: str,
    ref: str,
    *,
    names: tuple[str, ...] = ("Martin Durand",),
    items: tuple[tuple[str, int], ...] = (("F-101", 150_000),),
    status: str = "in_collection",
    pending: int = 0,
) -> AccountInfo:
    its = tuple(ItemInfo(f"{aid}-i{n}", r, b) for n, (r, b) in enumerate(items))
    return AccountInfo(aid, ref, status, "EUR", names, its, sum(b for _, b in items), pending)


def world(*accounts: AccountInfo, refs: dict[str, str] | None = None, links=None) -> Directory:  # type: ignore[no-untyped-def]
    return Directory.build(accounts, refs or {}, links)


def pay(text: str | None = None, amount: int = 10_000, **kw: object) -> PaymentIn:
    return PaymentIn(
        id=str(kw.pop("pid", "p1")),
        amount_minor=amount,
        currency="EUR",
        booking_date=DAY,
        remittance_text=text,
        **kw,  # type: ignore[arg-type]
    )


def one(p: PaymentIn, d: Directory) -> Decision:
    return match_all([p], d)[0]


A = account("A", "M-0042", items=(("FA-2026-00101", 150_000), ("FA-2026-00102", 80_000)))
B = account("B", "M-0077", names=("Lilas Finance",), items=(("FA-2026-00201", 50_000),))
REFS = {RF_A: "A", RF_B: "B"}


def test_the_rules_are_ordered_and_only_r1_to_r4_are_automatic() -> None:
    assert [r.code for r in RULES] == ["R1", "R2", "R3", "R4", "R5", "R6"]
    assert [r.automatic for r in RULES] == [True, True, True, True, False, False]
    assert all(r.title and r.explanation for r in RULES)


# -- R1 / R2 --------------------------------------------------------------------------------------


def test_r1_a_structured_rf_matches_its_file_whoever_pays() -> None:
    d = one(pay(creditor_reference=RF_A, payer_name="Quelqu'un d'autre"), world(A, B, refs=REFS))
    assert (d.outcome, d.rule, d.method, d.account_id) == ("auto", "R1", "rf_structured", "A")
    assert d.evidence["rf"] == [RF_A]


def test_r1_a_retired_reference_still_resolves() -> None:
    retired = rf_make("111122223333")
    d = one(pay(creditor_reference=retired), world(A, B, refs={**REFS, retired: "A"}))
    assert d.account_id == "A"


def test_r2_rf_in_the_text_whatever_the_spacing_case_or_line_breaks() -> None:
    g = rf_format(RF_A)
    for text in (
        f"VIR MARTIN-DURAND REGLT F-103 {g.lower()}",
        f"VIR {g[:9]}\n{g[10:]}",
        f"Ref {RF_A} merci beaucoup",
        f"paiement r f {g}",
    ):
        d = one(pay(text), world(A, B, refs=REFS))
        assert (d.rule, d.method, d.account_id) == ("R2", "rf_text", "A"), text


def test_r2_the_twelve_digits_alone() -> None:
    for text in ("REF 4821 9305 7612", "PAIEMENT 482193057612"):
        d = one(pay(text), world(A, B, refs=REFS))
        assert (d.rule, d.method, d.account_id) == ("R2", "rf_body", "A"), text


def test_r2_a_reference_followed_by_text_is_found_whatever_prefix_checks_by_chance() -> None:
    # Longer prefixes can pass mod 97 by chance (1 in 97): every candidate is looked up.
    s = read_signals(pay(f"{RF_A}MERCIBEAUCOUPPOURTOUT"))
    assert RF_A in s.text_refs


def test_two_references_of_two_files_are_ambiguous() -> None:
    d = one(pay(f"{rf_format(RF_A)} et {rf_format(RF_B)}"), world(A, B, refs=REFS))
    assert (d.outcome, d.review_reason, d.account_id) == ("ambiguous", "ambiguous", None)
    assert {c.account_id for c in d.candidates} == {"A", "B"}


def test_a_reference_and_an_invoice_of_another_file_are_ambiguous() -> None:
    d = one(pay("REGLT FA-2026-00201", creditor_reference=RF_A), world(A, B, refs=REFS))
    assert d.outcome == "ambiguous"
    assert [c.account_id for c in d.candidates] == ["A", "B"]


def test_a_reference_designates_the_invoices_of_its_file_it_cites() -> None:
    d = one(pay("REGLT FA-2026-00102", creditor_reference=RF_A), world(A, B, refs=REFS))
    assert d.account_id == "A" and d.designation == ("A-i1",)
    assert d.evidence["designation"] == ["FA-2026-00102"]


def test_short_invoice_numbers_designate_inside_the_matched_file_only() -> None:
    a = account("A", "M-0042", items=(("F-101", 1000), ("F-103", 2000)))
    d = one(pay(f"REGLT F-103 {RF_A}"), world(a, refs={RF_A: "A"}))
    assert d.designation == ("A-i1",)
    assert "F103" not in read_signals(pay("REGLT F-103")).tokens  # too short to look up everywhere


# -- R3 -------------------------------------------------------------------------------------------


def test_r3_an_invoice_number_backed_by_the_payers_name() -> None:
    d = one(pay("REGLT FACT FA-2026-00102", payer_name="M OU MME DURAND MARTIN"), world(A, B))
    assert (d.rule, d.method, d.account_id) == ("R3", "item_ref", "A")
    assert d.evidence["backed_by"] == "name" and d.designation == ("A-i1",)


def test_r3_backed_by_a_known_iban() -> None:
    p = pay("FACTURE FA-2026-00102", payer_name="SCI DU LAC", payer_iban=IBAN_X)
    d = one(p, world(A, B, links={IBAN_X: {"A": 1}}))
    assert d.account_id == "A" and d.evidence["backed_by"] == "iban"


def test_r3_backed_by_the_exact_balance_of_the_cited_invoices_or_of_the_file() -> None:
    d = one(pay("FA-2026-00101 FA-2026-00102", amount=230_000, payer_name="Tiers"), world(A, B))
    assert d.account_id == "A" and d.evidence["backed_by"] == "amount_items"
    d = one(pay("dossier M-0042", amount=230_000, payer_name="Tiers"), world(A, B))
    assert d.account_id == "A" and d.evidence["backed_by"] == "amount_account"


def test_r3_without_a_second_signal_is_only_a_suggestion() -> None:
    d = one(pay("REGLT FA-2026-00102", payer_name="Société Inconnue"), world(A, B))
    assert (d.outcome, d.review_reason, d.account_id) == ("suggestion", "no_match", None)
    assert [c.account_id for c in d.candidates] == ["A"] and d.acceptable


def test_r3_a_number_two_files_share_is_ambiguous() -> None:
    a2 = account("C", "X-1", names=("Martin Durand",), items=(("FA-2026-00102", 80_000),))
    d = one(pay("REGLT FA-2026-00102", payer_name="Martin Durand"), world(A, a2))
    assert d.outcome == "ambiguous" and not d.acceptable
    assert {c.account_id for c in d.candidates} == {"A", "C"}


def test_r3_numbers_of_two_files_are_ambiguous() -> None:
    d = one(pay("FA-2026-00101 FA-2026-00201", payer_name="Martin Durand"), world(A, B))
    assert d.outcome == "ambiguous"


def test_r3_a_month_designates_inside_the_file_another_number_names() -> None:
    lease = account("L", "BAIL-00123", items=(("2026-10", 60_000),))
    other = account("O", "BAIL-00999", names=("Autre",), items=(("2026-10", 70_000),))
    d = one(pay("LOYER 2026-10 BAIL-00123", payer_name="Martin Durand"), world(lease, other))
    assert d.account_id == "L" and d.designation == ("L-i0",)
    d = one(pay("LOYER 2026-10", payer_name="Martin Durand"), world(lease, other))
    assert not d.automatic and d.rule == "R6"  # a month names no file (review #1)


def test_r3_on_a_closed_file_is_a_suggestion_ops_must_look_at() -> None:
    closed = account("Z", "M-0099", items=(("FA-2026-00901", 0),), status="closed_paid")
    d = one(pay("FA-2026-00901", payer_name="Martin Durand"), world(closed))
    assert d.outcome == "suggestion" and not d.acceptable


def test_r3_on_a_file_not_confirmed_yet_is_automatic_and_gated_in_sql() -> None:
    staged = account("S", "M-0100", items=(("FA-2026-01001", 0),), status="staged")
    d = one(pay("FA-2026-01001", payer_name="Martin Durand"), world(staged))
    assert (d.outcome, d.account_id) == ("auto", "S")


# -- R4 -------------------------------------------------------------------------------------------


def test_r4_an_iban_that_paid_this_file_and_no_other() -> None:
    d = one(pay("VIREMENT", payer_iban=IBAN_X), world(A, B, links={IBAN_X: {"A": 2}}))
    assert (d.rule, d.method, d.account_id) == ("R4", "iban_memory", "A")
    assert not d.teaches_iban  # an R4 match does not teach the memory again


def test_r4_never_above_what_is_due_counting_this_runs_earlier_matches() -> None:
    a = account("A", "M-0042", items=(("FA-1", 15_000),), pending=2_000)
    d = world(a, links={IBAN_X: {"A": 1}})
    first, second = match_all(
        [
            pay(amount=10_000, pid="p1", payer_iban=IBAN_X),
            pay(amount=5_000, pid="p2", payer_iban=IBAN_X),
        ],
        d,
    )
    assert first.account_id == "A"
    assert (second.outcome, second.evidence["reason"]) == ("suggestion", "above_due")


def test_r4_an_iban_that_paid_two_open_files_is_ambiguous() -> None:
    d = one(pay(payer_iban=IBAN_X), world(A, B, links={IBAN_X: {"A": 1, "B": 1}}))
    assert d.outcome == "ambiguous"


def test_r4_a_closed_file_the_iban_paid_counts() -> None:
    """« This file and only this one » (founder #3): a file closed since (paid, recalled…) still
    counts, so a rematch never flips a payment to the other file once one closes (review #4)."""
    for status in ("closed_paid", "closed_recalled", "closed_settled", "closed_uncollectable"):
        closed = account("Z", "M-0099", status=status)
        d = one(pay(payer_iban=IBAN_X), world(A, closed, links={IBAN_X: {"A": 1, "Z": 3}}))
        assert (d.outcome, d.evidence["reason"]) == ("ambiguous", "iban_in_several_files"), status
        assert {c.account_id for c in d.candidates} == {"A", "Z"}  # ops forward if recalled


def test_r4_an_iban_that_paid_only_a_closed_file_matches_nothing() -> None:
    closed = account("Z", "M-0099", status="closed_recalled")
    d = one(pay(payer_iban=IBAN_X), world(A, closed, links={IBAN_X: {"Z": 1}}))
    assert not d.automatic and d.rule == "R6"


def test_r4_does_not_beat_a_cited_number_of_another_file() -> None:
    # The parent who paid A now pays B's invoice: R3 (unbacked) suggests B, R4 never runs.
    d = one(
        pay("FA-2026-00201", payer_name="Parent", payer_iban=IBAN_X),
        world(A, B, links={IBAN_X: {"A": 1}}),
    )
    assert d.outcome == "suggestion" and d.candidates[0].account_id == "B"


def test_r4_sees_the_links_this_run_teaches_whatever_the_order() -> None:
    """Review #11: the IBAN pays B by its RF in this statement; a credit without reference from
    the same IBAN is no longer « this file and only this one » for A, before or after."""
    teach = pay(creditor_reference=RF_B, pid="rf", payer_iban=IBAN_X, payer_name="Parent")
    bare = pay("VIREMENT", pid="bare", payer_iban=IBAN_X, payer_name="Parent")
    for order in ((teach, bare), (bare, teach)):
        out = {
            d.payment_id: d
            for d in match_all(order, world(A, B, refs=REFS, links={IBAN_X: {"A": 1}}))
        }
        assert (out["rf"].outcome, out["rf"].account_id) == ("auto", "B")
        assert (out["bare"].outcome, out["bare"].evidence["reason"]) == (
            "ambiguous",
            "iban_in_several_files",
        )
        assert {c.account_id for c in out["bare"].candidates} == {"A", "B"}


def test_r4_is_unchanged_by_this_runs_payments_to_the_same_file() -> None:
    teach = pay(creditor_reference=RF_A, pid="rf", payer_iban=IBAN_X)
    bare = pay("VIREMENT", pid="bare", payer_iban=IBAN_X)
    out = match_all([bare, teach], world(A, B, refs=REFS, links={IBAN_X: {"A": 1}}))
    assert [(d.outcome, d.account_id) for d in out] == [("auto", "A"), ("auto", "A")]


def test_the_callers_iban_links_are_not_changed_by_a_run() -> None:
    links = {IBAN_X: {"A": 1}}
    match_all(
        [pay(creditor_reference=RF_B, payer_iban=IBAN_X)], world(A, B, refs=REFS, links=links)
    )
    assert links == {IBAN_X: {"A": 1}}


# -- a reference the payer wrote that names no file (review #0, #3) ------------------------------

RF_B_TYPO = "RF72730261884528"  # B's reference, last digit changed: the check fails
RF_UNKNOWN = rf_make("111122223333")  # valid, but not a reference of this servicer


def test_rf_b_typo_fails_its_check() -> None:
    assert RF_B == "RF72730261884529" and not rf_valid(RF_B_TYPO) and rf_valid(RF_UNKNOWN)


def _unresolved_cases() -> list[tuple[str, PaymentIn]]:
    def from_x(text: str | None = None, ref: str | None = None) -> PaymentIn:
        return pay(text, creditor_reference=ref, payer_iban=IBAN_X, payer_name="NGUYEN THI LAN")

    return [
        ("structured typo", from_x(ref=RF_B_TYPO)),
        ("text typo", from_x(f"LOYER {rf_format(RF_B_TYPO)}")),
        ("text typo glued", from_x(f"loyer {RF_B_TYPO.lower()}")),
        ("structured unknown", from_x(ref=RF_UNKNOWN)),
        ("text unknown", from_x(f"REF {rf_format(RF_UNKNOWN)}")),
        ("text without a body", from_x("REGLT RF72 MERCI")),
    ]


def test_r4_never_overrides_a_reference_the_payer_wrote_that_names_no_file() -> None:
    """The IBAN paid A only; the payer wrote an RF that resolves to nothing (a typo of B's, or
    another creditor's): ops decide, with the reference in front of them."""
    for case, p in _unresolved_cases():
        d = one(p, world(A, B, refs=REFS, links={IBAN_X: {"A": 1}}))
        assert (d.outcome, d.rule, d.evidence["reason"]) == (
            "suggestion",
            "R4",
            "unresolved_reference",
        ), case
        assert d.evidence["unresolved"] and not d.acceptable, case
        (c,) = d.candidates
        assert c.account_id == "A" and c.signals["unresolved"] == d.evidence["unresolved"], case


def test_an_unresolved_reference_is_reported_as_written() -> None:
    p = pay(f"LOYER {rf_format(RF_B_TYPO)}\nmerci", payer_iban=IBAN_X)
    d = one(p, world(A, B, refs=REFS, links={IBAN_X: {"A": 1}}))
    assert d.evidence["unresolved"] == [rf_format(RF_B_TYPO)]
    d = one(
        pay(creditor_reference=RF_UNKNOWN, payer_iban=IBAN_X), world(A, links={IBAN_X: {"A": 1}})
    )
    assert d.evidence["unresolved"] == [RF_UNKNOWN]


def test_two_references_one_mistyped_are_never_automatic() -> None:
    """Review #3: the payer names A and (with a typo) B: the valid one does not take it all."""
    both = f"REGLT {rf_format(RF_A)} ET {rf_format(RF_B_TYPO)}"
    for p in (
        pay(both, amount=145_000),
        pay(f"ET {rf_format(RF_B_TYPO)}", amount=145_000, creditor_reference=RF_A),
        pay(f"REGLT {rf_format(RF_A)}", amount=145_000, creditor_reference=RF_B_TYPO),
        pay(f"{RF_A} {RF_UNKNOWN}", amount=145_000),
    ):
        d = one(p, world(A, B, refs=REFS))
        assert (d.outcome, d.evidence["reason"]) == ("suggestion", "unresolved_reference"), p
        assert d.candidates[0].account_id == "A" and not d.acceptable


def test_a_cited_number_with_an_unresolved_reference_is_a_suggestion() -> None:
    p = pay(f"FACT FA-2026-00102 {rf_format(RF_B_TYPO)}", payer_name="Martin Durand")
    d = one(p, world(A, B, refs=REFS))
    assert (d.outcome, d.evidence["reason"]) == ("suggestion", "unresolved_reference")


def test_an_unresolved_reference_alone_is_reported_in_the_queue() -> None:
    d = one(pay(f"REGLT {rf_format(RF_B_TYPO)}", payer_name="Inconnu"), world(A, B, refs=REFS))
    assert d.rule == "R6" and d.evidence["unresolved"] == [rf_format(RF_B_TYPO)]


def test_the_same_reference_written_twice_resolves() -> None:
    p = pay(f"{rf_format(RF_A)} / {RF_A}", creditor_reference=RF_A, payer_iban=IBAN_X)
    d = one(p, world(A, B, refs=REFS, links={IBAN_X: {"A": 1}}))
    assert (d.outcome, d.rule, d.account_id) == ("auto", "R1", "A")
    assert read_signals(p).unresolved(REFS) == ()


# -- dates and numbers made of digits (review #1) -------------------------------------------------

DUPONT = account(
    "X",
    "BAIL-000101",
    names=("DUPONT Jean",),
    items=(("2026-08", 65_000), ("2026-09", 65_000), ("2026-10", 65_000)),
)
DURAND = account(
    "Y",
    "BAIL-000102",
    names=("DURAND Sophie",),
    items=(("2026-09", 65_000), ("2026-10", 65_000), ("2026-11", 65_000)),
)


def test_a_month_one_file_alone_has_never_names_it() -> None:
    """DUPONT pays his rent citing November, which only DURAND's lease has, for the same rent."""
    for text in ("LOYER 2026-11", "LOYER 11/2026", "loyer 2026 11"):
        p = pay(text, amount=65_000, payer_name="DUPONT JEAN", payer_iban=IBAN_X)
        d = one(p, world(DUPONT, DURAND, links={IBAN_X: {"X": 1}}))
        assert (d.outcome, d.rule, d.account_id) == ("auto", "R4", "X"), text
        d = one(replace(p, payer_iban=IBAN_Y), world(DUPONT, DURAND))
        assert not d.automatic and d.account_id is None, text


def test_dates_are_not_looked_up_across_files_but_designate_inside_one() -> None:
    for written, key in (
        ("2026-11", "202611"),
        ("11/2026", "112026"),
        ("2026-11-05", "20261105"),
        ("05/11/2026", "05112026"),
    ):
        assert not is_lookup_token(key), written
        s = read_signals(pay(f"LOYER {written} BAIL-000102"))
        assert key not in s.tokens and key in s.short_tokens, written
    assert is_lookup_token("BAIL000102") and is_lookup_token("FA202600042")
    assert is_lookup_token("7730219")  # seven digits: not a date


def test_r3_a_number_of_digits_only_is_not_backed_by_the_amount_alone() -> None:
    c = account("C", "M-0500", names=("Lilas Finance",), items=(("7730219", 42_000),))
    p = pay("FACTURE 7730219", amount=42_000, payer_name="Tiers Payeur")
    d = one(p, world(c, A))
    assert (d.outcome, d.evidence["reason"]) == ("suggestion", "not_corroborated")
    d = one(replace(p, payer_name="LILAS FINANCE"), world(c, A))
    assert (d.outcome, d.evidence["backed_by"]) == ("auto", "name")
    d = one(replace(p, payer_iban=IBAN_X), world(c, A, links={IBAN_X: {"C": 1}}))
    assert (d.outcome, d.evidence["backed_by"]) == ("auto", "iban")


def test_r3_a_label_and_a_month_is_not_backed_by_the_amount_alone() -> None:
    c = account("C", "M-0500", names=("Lilas Finance",), items=(("LOYER-2026-11", 42_000),))
    d = one(pay("LOYER 2026-11", amount=42_000, payer_name="Tiers Payeur"), world(c, A))
    assert not d.automatic


# -- R5 / R6 --------------------------------------------------------------------------------------


def test_r5_the_exact_balance_and_a_very_close_name_is_a_suggestion() -> None:
    d = one(pay("SOLDE", amount=230_000, payer_name="DURAND MARTIN"), world(A, B))
    assert (d.rule, d.outcome, d.review_reason, d.account_id) == (
        "R5",
        "suggestion",
        "no_match",
        None,
    )
    assert d.acceptable and d.candidates[0].account_id == "A"


def test_r5_two_equally_good_files_are_never_one_tap() -> None:
    twin = account("T", "M-0043", items=(("FA-9", 230_000),))
    d = one(pay(amount=230_000, payer_name="Martin Durand"), world(A, twin))
    assert d.rule == "R5" and not d.acceptable and len(d.candidates) == 2


def test_r6_the_amount_alone_is_only_a_hint() -> None:
    d = one(pay(amount=230_000, payer_name="Quelqu'un"), world(A, B))
    assert (d.rule, d.outcome, d.acceptable) == ("R6", "none", False)
    assert d.candidates[0].strength == 1


def test_r6_names_found_by_the_search() -> None:
    d = world(A, B)
    d.by_name["p1"] = ("A",)
    out = one(pay(payer_name="DURAND MARTIN"), d)
    assert out.rule == "R6" and out.candidates[0].account_id == "A" and not out.acceptable


def test_nothing_known_goes_to_the_queue_as_no_match() -> None:
    d = one(pay("CADEAU", payer_name="Inconnu", payer_iban=IBAN_Y), world(A, B, refs=REFS))
    assert (d.rule, d.review_reason, d.candidates) == ("R6", "no_match", ())


# -- decided by ops -------------------------------------------------------------------------------


def test_a_payment_ops_handled_gets_suggestions_never_an_automatic_match() -> None:
    p = PaymentIn("p1", 10_000, "EUR", DAY, creditor_reference=RF_A, suggest_only=True)
    d = one(p, world(A, B, refs=REFS))
    assert (d.outcome, d.candidates[0].account_id) == ("suggestion", "A")


def test_a_file_ops_took_the_payment_away_from_is_never_proposed_again() -> None:
    p = PaymentIn("p1", 10_000, "EUR", DAY, creditor_reference=RF_A, excluded=frozenset({"A"}))
    d = one(p, world(A, B, refs=REFS))
    assert d.account_id is None and all(c.account_id != "A" for c in d.candidates)


# -- names and keys -------------------------------------------------------------------------------


def test_names_compare_without_titles_legal_forms_order_case_or_accents() -> None:
    assert similarity("M OU MME DUPONT JEAN", "Jean Dupont") == 1.0
    assert similarity("SARL BOULANGERIE DURAND", "Boulangerie Durand") == 1.0
    assert similarity("Éric BOURDON", "BOURDON Eric") == 1.0
    assert similarity("DUPOND JEAN", "Jean Dupont") >= 0.6  # one typo still backs a number
    assert similarity("MARTIN SAS", "Dupont SAS") == 0.0  # the legal form alone says nothing
    assert similarity(None, "x") == 0.0


def test_reference_keys_are_ascii_letters_and_digits() -> None:
    assert ref_key("FA-2026/00042 ") == "FA202600042"
    assert ref_key("n°CC2025") == "NCC2025"


def test_ligatures_are_written_out() -> None:
    """Review #5: Œ and Æ are not decomposed by NFKD; banks print OE and AE."""
    assert name_words("SARL CŒUR DE LION") == ("COEUR", "DE", "LION")
    assert similarity("COEUR DE LION", "SARL CŒUR DE LION") == 1.0
    assert similarity("LAETITIA DURAND", "DURAND Lætitia") == 1.0
    assert similarity("STRASSE", "Straße") == 1.0


def test_surname_particles_are_name_words() -> None:
    """Review #2: LE, DE, DU… are surnames or parts of them (Lê, Le Roux, De Sousa)."""
    assert name_words("LE THI HOA") == ("LE", "THI", "HOA")
    assert name_words("M OU MME DE SOUSA") == ("DE", "SOUSA")
    assert similarity("LE THI HOA", "TRAN Thi Hoa") < 0.6
    assert similarity("M LE VAN NAM", "PHAM Van Nam") < 0.6
    assert similarity("LE ROUX PIERRE", "Pierre Le Roux") == 1.0


def test_initials_must_agree() -> None:
    assert similarity("J DUPONT", "DUPONT Marie") == 0.0
    alone = similarity("DUPONT", "Jean Dupont")
    assert similarity("DUPONT M", "Jean Dupont") == alone > 0  # M is « Monsieur », not an initial
    assert similarity("J DUPONT", "Jean Dupont") == alone  # an initial gates, it adds nothing
    assert similarity("J.-P. DUPONT", "Jean-Pierre Dupont") > 0
    assert similarity("J.-P. DUPONT", "Marie-Paule Dupont") == 0.0
    assert similarity("J DUPONT", "Dupont SARL") == 1.0  # a single word: nothing to contradict
    assert similarity("DUPONT", "DUPONT J") == 1.0
    assert similarity("JEANNE D ARC", "Jeanne d'Arc") == 1.0  # d', l': elisions, not initials
    assert similarity("DUBOIS DUMAS S.A.R.L.", "Dubois Dumas") == 1.0  # a legal form spelt out
    assert similarity("S A R L DUBOIS DUMAS", "Dubois Dumas SARL") == 1.0


def test_shared_words_count_a_typo_in_a_long_word() -> None:
    assert shared_words("DUPOMT JEAN", "Jean Dupont") == ("JEAN", "DUPONT")
    assert shared_words("M OU MME MARTINS", "Martin SARL") == ("MARTIN",)
    assert shared_words("JEAN", "Jeanne Dupont") == ()  # short words must be equal


# -- R3 name backing: one shared word must be rare (review #2) ------------------------------------

GUILLOT_SA = account("G1", "M-0601", names=("Guillot SA",), items=(("FA-2026-00500", 90_000),))
GUILLOT = account("G2", "M-0602", names=("Guillot",), items=(("FA-2026-00499", 70_000),))
DUBOIS_DUMAS = account(
    "D1", "M-0603", names=("Dubois Dumas S.A.R.L.",), items=(("FA-2026-00700", 90_000),)
)
DUBOIS = account("D2", "M-0604", names=("Dubois",), items=(("FA-2026-00701", 70_000),))


def test_r3_one_shared_word_another_file_also_has_does_not_back_a_number() -> None:
    """The debtor of G2 « Guillot » mistypes his invoice number FA-2026-00499 as 00500, which is
    G1's « Guillot SA »: the name GUILLOT is on two files, so it backs neither."""
    for payer, cited, file in (
        ("GUILLOT", "FA-2026-00500", "G1"),
        ("M OU MME GUILLOT", "FA-2026-00500", "G1"),
        ("DUBOIS", "FA-2026-00700", "D1"),
        ("Dubois Dumas", "FA-2026-00701", "D2"),
    ):
        d = one(
            pay(f"REGLT FACT {cited}", payer_name=payer),
            world(GUILLOT_SA, GUILLOT, DUBOIS_DUMAS, DUBOIS),
        )
        assert (d.outcome, d.evidence["reason"]) == ("suggestion", "not_corroborated"), payer
        assert d.candidates[0].account_id == file


def test_r3_one_shared_word_no_other_file_has_backs_a_number() -> None:
    d = one(pay("REGLT FACT FA-2026-00500", payer_name="GUILLOT"), world(GUILLOT_SA, DUBOIS))
    assert (d.outcome, d.account_id, d.evidence["backed_by"]) == ("auto", "G1", "name")
    assert d.evidence["rare_word"] == "GUILLOT"


def test_r3_one_word_written_with_a_typo_never_backs_a_number_alone() -> None:
    """« MARTINS » is one letter from « Martin »: a word no other file has, but the payer may be
    the debtor of « Martins SARL » with a typo in the invoice number."""
    martins = account("M1", "M-0701", names=("Martins SARL",), items=(("FA-2026-00800", 90_000),))
    martin = account("M2", "M-0702", names=("Martin SARL",), items=(("FA-2026-00801", 70_000),))
    d = one(pay("REGLT FACT FA-2026-00801", payer_name="MARTINS"), world(martins, martin))
    assert (d.outcome, d.evidence["reason"]) == ("suggestion", "not_corroborated")


def test_r3_two_shared_words_back_a_number_however_common() -> None:
    twins = account("T", "M-0605", items=(("FA-2026-00900", 1_000),))  # another Martin Durand
    for payer in ("M OU MME DURAND MARTIN", "DURAMD MARTIN"):
        d = one(pay("REGLT FACT FA-2026-00102", payer_name=payer), world(A, B, twins))
        assert (d.account_id, d.evidence["backed_by"]) == ("A", "name"), payer


def test_r3_name_backing_waits_for_the_name_index_the_job_builds_later() -> None:
    """The job builds the name index with the remainder (after R4): a decision that rests on one
    rare word waits for it and comes out as in the eval's directory."""
    files = (GUILLOT_SA, DUBOIS)
    p = pay("REGLT FACT FA-2026-00500", payer_name="GUILLOT")
    built = world(*files)
    lazy = world(*files)
    index, lazy.names = lazy.names, None
    seen: list[str] = []

    def remainder(rest: Sequence[tuple[PaymentIn, Signals]]) -> None:
        seen.extend(q.id for q, _ in rest)
        lazy.names = index

    assert match_all([p], lazy, remainder) == match_all([p], built)
    assert seen == ["p1"]
    nothing = world(*files)
    nothing.names = None
    d = match_all([p], nothing, lambda rest: None)[0]
    assert d.outcome == "suggestion"  # no index: the word is not known to be rare


def test_r4_waits_for_an_r3_decision_on_the_same_iban_or_file() -> None:
    """An R3 decision waiting for the name index may teach the IBAN another file, or take what is
    left to pay: R4 on that IBAN or that file is decided after it, in both directions."""
    g = account("G1", "M-0601", names=("Guillot SA",), items=(("FA-2026-00500", 90_000),))
    p1 = pay("REGLT FACT FA-2026-00500", pid="r3", payer_name="GUILLOT", payer_iban=IBAN_X)
    p2 = pay("VIREMENT", pid="r4", payer_iban=IBAN_X)
    for order in ((p1, p2), (p2, p1)):
        out = {d.payment_id: d for d in match_all(order, world(g, A, links={IBAN_X: {"A": 1}}))}
        assert out["r3"].account_id == "G1" and out["r4"].outcome == "ambiguous"
    # Another file has GUILLOT: the R3 payment is only a suggestion, so R4 matches A as usual.
    out = {
        d.payment_id: d for d in match_all([p1, p2], world(g, GUILLOT, A, links={IBAN_X: {"A": 1}}))
    }
    assert out["r3"].outcome == "suggestion" and out["r4"].account_id == "A"


def test_r4_due_counts_a_waiting_r3_match_only_once_it_is_made() -> None:
    g = account("G1", "M-0601", names=("Guillot SA",), items=(("FA-2026-00500", 90_000),))
    other = account("G3", "M-0603", names=("Guillot",), items=(("FA-2026-00900", 5_000),))
    cited = pay("REGLT FACT FA-2026-00500", pid="r3", amount=60_000, payer_name="GUILLOT")
    bare = pay("VIREMENT", pid="r4", amount=40_000, payer_iban=IBAN_X)
    links = {IBAN_X: {"G1": 1}}
    out = {d.payment_id: d for d in match_all([cited, bare], world(g, other, links=links))}
    assert out["r3"].outcome == "suggestion" and out["r4"].account_id == "G1"  # 40,000 ≤ 90,000
    out = {d.payment_id: d for d in match_all([cited, bare], world(g, links=links))}
    assert out["r3"].account_id == "G1"  # matched: 30,000 left, the 40,000 is above it
    assert (out["r4"].outcome, out["r4"].evidence["reason"]) == ("suggestion", "above_due")


# -- properties -----------------------------------------------------------------------------------

BODIES = st.lists(st.from_regex(r"[0-9]{12}", fullmatch=True), min_size=2, max_size=6, unique=True)


def _typo(rf: str, pos: int, kind: int, digit: str) -> str | None:
    digits = list(rf[2:])
    if kind == 0:
        if digits[pos] == digit:
            return None
        digits[pos] = digit
    else:
        if pos == len(digits) - 1 or digits[pos] == digits[pos + 1]:
            return None
        digits[pos], digits[pos + 1] = digits[pos + 1], digits[pos]
    return "RF" + "".join(digits)


@settings(max_examples=400, deadline=None)
@given(
    bodies=BODIES,
    pos=st.integers(0, 13),
    kind=st.integers(0, 1),
    digit=st.sampled_from("0123456789"),
    style=st.integers(0, 3),
    linked=st.sampled_from([None, 0, 1]),
    other=st.booleans(),
)
def test_an_rf_with_one_typo_never_matches_automatically(  # noqa: PLR0913, PLR0917 - the cases
    bodies: list[str],
    pos: int,
    kind: int,
    digit: str,
    style: int,
    linked: int | None,
    other: bool,
) -> None:
    """Whoever pays: from an IBAN that paid the file the reference is for (or another file), and
    with another file's valid reference written next to it (review #0, #3)."""
    refs = {rf_make(b): f"acc{i}" for i, b in enumerate(bodies)}
    target = rf_make(bodies[0])
    bad = _typo(target, pos, kind, digit)
    if bad is None:
        return
    text = (None, f"REGLT {bad}", f"VIR {rf_format(bad).lower()}", f"Ref {rf_format(bad)}")[style]
    if other:
        text = f"{text or ''} {rf_format(rf_make(bodies[1]))}"
    p = pay(
        text,
        creditor_reference=bad if style == 0 else None,
        payer_name="Inconnu",
        payer_iban=IBAN_X,
    )
    accounts = [account(a, f"X-{i}", names=("Nom",)) for i, a in enumerate(refs.values())]
    links = {IBAN_X: {f"acc{linked}": 1}} if linked is not None else None
    d = one(p, world(*accounts, refs=refs, links=links))
    assert not d.automatic, (bad, text)


@settings(max_examples=150, deadline=None)
@given(
    order=st.permutations(["rf_b", "bare1", "bare2", "rf_a"]),
    teach_b=st.booleans(),
)
def test_r4_never_matches_a_file_when_the_run_shows_the_iban_paid_another(
    order: list[str], teach_b: bool
) -> None:
    """Whatever the order of a statement's lines, R4 never matches A while a line of the same
    statement pays B from that IBAN (review #11)."""
    lines = {
        "rf_b": pay(creditor_reference=RF_B if teach_b else RF_A, pid="rf_b", payer_iban=IBAN_X),
        "rf_a": pay(f"REGLT {RF_A}", pid="rf_a", payer_iban=IBAN_X),
        "bare1": pay("VIREMENT", pid="bare1", amount=1_000, payer_iban=IBAN_X),
        "bare2": pay(pid="bare2", amount=1_000, payer_iban=IBAN_X),
    }
    out = match_all([lines[k] for k in order], world(A, B, refs=REFS, links={IBAN_X: {"A": 1}}))
    bare = [d for d in out if d.payment_id.startswith("bare")]
    if teach_b:
        assert all(d.outcome == "ambiguous" for d in bare)
    else:
        assert all((d.outcome, d.account_id) == ("auto", "A") for d in bare)


@settings(max_examples=200, deadline=None)
@given(
    year=st.integers(1990, 2099),
    month=st.integers(1, 12),
    day=st.integers(1, 28),
    shape=st.sampled_from(
        ["{y}-{m:02d}", "{m:02d}/{y}", "{y}{m:02d}{d:02d}", "{d:02d}.{m:02d}.{y}"]
    ),
    amount=st.integers(1, 200_000),
)
def test_a_date_never_names_a_file(
    year: int, month: int, day: int, shape: str, amount: int
) -> None:
    """A date one file alone has, at the amount of that item, from a stranger: never automatic."""
    written = shape.format(y=year, m=month, d=day)
    only = account("Y", "BAIL-7", names=("Durand Sophie",), items=((written, amount),))
    p = pay(f"LOYER {written}", amount=amount, payer_name="Martin Paul", payer_iban=IBAN_Y)
    assert not one(p, world(only, A)).automatic


@settings(max_examples=200, deadline=None)
@given(
    kind=st.sampled_from(["token", "iban", "rf"]),
    names=st.lists(
        st.sampled_from(["Martin Durand", "Lilas", "Jean Dupont"]), min_size=2, max_size=2
    ),
    amount=st.integers(1, 500_000),
)
def test_a_tie_never_matches_automatically(kind: str, names: list[str], amount: int) -> None:
    """Two files the payment points to equally: never automatic, never one tap."""
    x = account("X", "K-1", names=(names[0],), items=(("FA-2026-55555", 300_000),))
    y = account("Y", "K-2", names=(names[1],), items=(("FA-2026-55555", 300_000),))
    refs = {RF_A: "X", RF_B: "Y"}
    links = {IBAN_X: {"X": 1, "Y": 1}}
    text = {"token": "FA-2026-55555", "iban": "VIREMENT", "rf": f"{RF_A} {RF_B}"}[kind]
    p = pay(text, amount=amount, payer_name=names[0], payer_iban=IBAN_X if kind == "iban" else None)
    d = one(p, world(x, y, refs=refs, links=links))
    assert not d.automatic and not d.acceptable


@settings(max_examples=200, deadline=None)
@given(
    amount=st.integers(1, 1_000_000), name=st.sampled_from(["Martin Durand", "DURAND MARTIN", "X"])
)
def test_the_amount_and_the_name_alone_never_match_automatically(amount: int, name: str) -> None:
    a = account("A", "M-0042", items=(("FA-1", amount),))
    d = one(pay("VIREMENT", amount=amount, payer_name=name, payer_iban=IBAN_Y), world(a))
    assert not d.automatic


def test_the_eval_on_a_small_world_reaches_the_threshold_without_a_wrong_match() -> None:
    score, _ = run(accounts=2_000, credits=4_000, seed=3)
    assert score.wrong == [] and score.bad_reason == [] and score.policy_violations == []
    assert score.rate >= 0.95, score.report()


def test_the_jobs_loading_order_gives_the_evals_decisions() -> None:
    """The job has no name index, amount or name candidates until `remainder` (called once,
    after R4): every decision must be what the eval's full directory gives."""
    world_ = synthetic_world(2_000, seed=5)
    payments = [
        c.payment(f"p{k}", DAY) for k, c in enumerate(generate_credits(world_, 4_000, seed=6))
    ]
    full = world_.directory()
    lazy = world_.directory()
    index, amounts = lazy.names, lazy.by_amount
    lazy.names, lazy.by_amount = None, {}
    calls: list[int] = []

    def remainder(rest: Sequence[tuple[PaymentIn, Signals]]) -> None:
        calls.append(len(rest))
        wanted = {p.amount_minor for p, _ in rest}
        lazy.by_amount = {k: v for k, v in amounts.items() if k in wanted}
        lazy.names = index
        lazy.search_names(p for p, _ in rest)

    assert match_all(payments, lazy, remainder) == match_all(payments, full)
    assert len(calls) == 1


def test_the_eval_fails_on_an_automatic_match_founder_rule_3_forbids() -> None:
    """Review #20: a credit the truth sends to the queue (name and amount only…) matched
    automatically, even to the right file, fails the eval like a wrong match."""
    c = Credit(10_000, "DURAND MARTIN", IBAN_Y, ("SOLDE",), None, "A", "no_match", "name_amount")
    score = Score()
    score.add(c, "l1", "A", None)
    assert score.wrong == [] and len(score.policy_violations) == 1
    assert score.report()["policy_violations"] == 1
    assert failures(score, 0.0) == ["policy_violations"]
    ok = Score()
    ok.add(c, "l1", None, "no_match")
    assert failures(ok, 0.0) == []


def test_the_generator_writes_every_hard_case() -> None:
    world_ = synthetic_world(2_000, seed=3)
    credits = generate_credits(world_, 4_000, seed=4)
    written = {c.scenario for c in credits}
    assert written >= {name for name, _ in MIX}, {name for name, _ in MIX} - written
    assert all(c.expect == EXPECT[c.scenario] for c in credits)
    assert abs(sum(w for _, w in MIX) - 1) < 1e-9
    pairs = [c for c in credits if c.scenario in ("joint_rf", "joint_noref")]
    assert len({c.iban for c in pairs}) * 2 == len(pairs)  # each IBAN pays one file by RF, one bare
