"""Reconciliation rules R1-R6 (M2-08, design §8.4, founder decision #3): one test per rule and its
limits, and properties: a reference with one typo never matches automatically, a tie never does,
nor does an amount alone."""

import random
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
    match_all,
    read_signals,
    ref_key,
    similarity,
)
from collectoo_worker.payments.reconciliation_eval import run
from collectoo_worker.payments.rf import rf_format, rf_make
from collectoo_worker.synth.ids import iban_fr

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


def test_r3_a_number_shared_by_many_files_is_narrowed_by_another() -> None:
    lease = account("L", "BAIL-00123", items=(("2026-10", 60_000),))
    other = account("O", "BAIL-00999", names=("Autre",), items=(("2026-10", 70_000),))
    d = one(pay("LOYER 2026-10 BAIL-00123", payer_name="Martin Durand"), world(lease, other))
    assert d.account_id == "L" and d.designation == ("L-i0",)
    d = one(pay("LOYER 2026-10", payer_name="Martin Durand"), world(lease, other))
    assert d.outcome == "ambiguous"


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


def test_r4_a_closed_file_does_not_count() -> None:
    closed = account("Z", "M-0099", status="closed_paid")
    d = one(pay(payer_iban=IBAN_X), world(A, closed, links={IBAN_X: {"A": 1, "Z": 3}}))
    assert d.account_id == "A"


def test_r4_does_not_beat_a_cited_number_of_another_file() -> None:
    # The parent who paid A now pays B's invoice: R3 (unbacked) suggests B, R4 never runs.
    d = one(
        pay("FA-2026-00201", payer_name="Parent", payer_iban=IBAN_X),
        world(A, B, links={IBAN_X: {"A": 1}}),
    )
    assert d.outcome == "suggestion" and d.candidates[0].account_id == "B"


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


@settings(max_examples=300, deadline=None)
@given(
    bodies=BODIES,
    pos=st.integers(0, 13),
    kind=st.integers(0, 1),
    digit=st.sampled_from("0123456789"),
    style=st.integers(0, 3),
)
def test_an_rf_with_one_typo_never_matches_automatically(
    bodies: list[str], pos: int, kind: int, digit: str, style: int
) -> None:
    refs = {rf_make(b): f"acc{i}" for i, b in enumerate(bodies)}
    target = rf_make(bodies[0])
    bad = _typo(target, pos, kind, digit)
    if bad is None:
        return
    text = (None, f"REGLT {bad}", f"VIR {rf_format(bad).lower()}", f"Ref {rf_format(bad)}")[style]
    p = pay(text, creditor_reference=bad if style == 0 else None, payer_name="Inconnu")
    accounts = [account(a, f"X-{i}", names=("Nom",)) for i, a in enumerate(refs.values())]
    d = one(p, world(*accounts, refs=refs))
    assert not d.automatic, (bad, text)


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
    assert score.wrong == [] and score.bad_reason == []
    assert score.rate >= 0.95, score.report()
