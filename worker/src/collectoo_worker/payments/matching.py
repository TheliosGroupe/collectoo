"""Reconciliation (M2-08): which file (account) a payment pays. Deterministic rules, no model.

Design: docs/design/m2b-payments.md §8.4; founder decision #3 (ADR-0013): a payment is matched
automatically only on a valid RF reference, on an invoice or file number backed by the payer's name,
a known IBAN or the exact amount, or on an IBAN that already paid this file and only this one. A
name plus an amount is only a suggestion; the amount alone never is anything.

The rules run in order; a rule only sees the payments the previous ones left (`RULES` below, in
French for ops: the queue shows them). Every decision carries its evidence. Precision first: when
two files are named, nothing is automatic (the payment goes to ops as `ambiguous`), and a
reference that fails its check digits is never guessed from.

This module is pure: the `payments.match` job loads a `Directory` from the database (only what the
payments' signals need), runs `match_all`, and applies the decisions set-based in SQL, where the
gating of design §8.4 (file not confirmed, closed, held, nothing due…) is decided. The
reconciliation eval runs the same code on a synthetic world (`collectoo_worker.payments.eval`).
"""

from __future__ import annotations

import re
import unicodedata
from collections import Counter
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field
from datetime import date
from functools import lru_cache
from typing import Any

from collectoo_worker.payments.rf import iban_valid, rf_make, rf_normalise, rf_valid

RULE_VERSION = "match-1"
NAME_CORROBORATES = 0.6  # R3: the payer's name backs a cited reference
NAME_SUGGESTS = 0.85  # R5: with the exact amount, a suggestion (never automatic)
MIN_TOKEN = 5  # a reference looked up across the servicer's files
MIN_DESIGNATION = 3  # a reference looked up among the matched file's own invoices
MAX_TOKEN = 35
MAX_CANDIDATES = 3
CLOSED = frozenset({"closed_paid", "closed_settled", "closed_uncollectable", "closed_recalled"})
AUTO_METHODS = ("rf_structured", "rf_text", "rf_body", "item_ref", "iban_memory")
# Decisions that teach the IBAN memory (an R4 match only refreshes it: no self-reinforcement).
TEACHES_IBAN = frozenset({"rf_structured", "rf_text", "rf_body", "item_ref", "manual"})


@dataclass(frozen=True, slots=True)
class Rule:
    code: str
    methods: tuple[str, ...]  # payment_match.method of its automatic decisions
    automatic: bool
    title: str  # French, shown to ops
    explanation: str


RULES: tuple[Rule, ...] = (
    Rule(
        "R1",
        ("rf_structured",),
        True,
        "Référence RF structurée",
        "Le virement porte, dans sa zone de référence structurée, la référence RF valide d'un"
        " dossier.",
    ),
    Rule(
        "R2",
        ("rf_text", "rf_body"),
        True,
        "Référence RF dans le libellé",
        "Le libellé contient la référence RF valide d'un dossier (espaces, minuscules et retours à"
        " la ligne tolérés), ou ses 12 chiffres seuls. Une référence dont la clé est fausse n'est"
        " jamais devinée.",
    ),
    Rule(
        "R3",
        ("item_ref",),
        True,
        "Numéro de facture ou de dossier confirmé",
        "Le libellé cite des numéros de facture ou de dossier qui désignent tous un seul dossier,"
        " et un autre signal le confirme : IBAN déjà connu pour ce dossier, nom du payeur proche"
        " d'une partie au dossier (60 % au moins), ou montant égal au solde des factures citées ou"
        " du dossier. Sans confirmation : simple suggestion.",
    ),
    Rule(
        "R4",
        ("iban_memory",),
        True,
        "IBAN connu",
        "L'IBAN du payeur a déjà payé ce dossier, et aucun autre dossier ouvert, et le montant ne"
        " dépasse pas ce qui reste dû.",
    ),
    Rule(
        "R5",
        (),
        False,
        "Montant et nom",
        "Le montant est égal au solde d'un dossier ou d'une facture et le nom du payeur est très"
        " proche (85 % au moins) : suggestion seulement, jamais automatique.",
    ),
    Rule(
        "R6",
        (),
        False,
        "À traiter",
        "Aucune règle ne désigne un seul dossier : jusqu'à 3 dossiers proposés, avec ce qui les a"
        " classés.",
    ),
)
RULES_BY_CODE = {r.code: r for r in RULES}


# -- inputs ---------------------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class PaymentIn:
    """What matching reads of a payment (bank facts)."""

    id: str
    amount_minor: int
    currency: str
    booking_date: date
    payer_name: str | None = None
    payer_iban: str | None = None
    remittance_text: str | None = None
    creditor_reference: str | None = None
    other_names: tuple[str, ...] = ()  # the ultimate debtor named by the bank, if any
    # A payment ops decided by hand (assigned or unassigned): rules only suggest from then on, and
    # never the files ops took it away from.
    suggest_only: bool = False
    excluded: frozenset[str] = frozenset()


@dataclass(frozen=True, slots=True)
class ItemInfo:
    id: str
    ref: str  # as the seller wrote it
    balance_minor: int

    @property
    def key(self) -> str:
        return ref_key(self.ref)


@dataclass(frozen=True, slots=True)
class AccountInfo:
    id: str
    external_ref: str
    status: str
    currency: str
    names: tuple[str, ...] = ()  # every party of the file (debtor, co-debtor, guarantor…)
    items: tuple[ItemInfo, ...] = ()
    balance_minor: int = 0  # Σ receivable (ledger)
    pending_minor: int = 0  # payments matched to it and not allocated yet

    @property
    def closed(self) -> bool:
        return self.status in CLOSED

    @property
    def open(self) -> bool:
        """Confirmed and not closed: what IBAN memory may match."""
        return self.status != "staged" and not self.closed


@dataclass
class Directory:
    """What the database knows that the payments' signals point to."""

    references: dict[str, str] = field(default_factory=dict)  # RF (active or retired) -> account
    tokens: dict[str, frozenset[str]] = field(default_factory=dict)  # ref key -> accounts
    accounts: dict[str, AccountInfo] = field(default_factory=dict)
    iban_links: dict[str, dict[str, int]] = field(default_factory=dict)  # IBAN -> {account: n}
    # Remainder only (R5/R6): accounts whose open balance, or one of whose items', equals an
    # amount (common amounts are left out by the loader), and accounts found by a name search.
    by_amount: dict[int, frozenset[str]] = field(default_factory=dict)
    by_name: dict[str, tuple[str, ...]] = field(default_factory=dict)  # payment id -> accounts

    @classmethod
    def build(
        cls,
        accounts: Iterable[AccountInfo],
        references: dict[str, str],
        iban_links: dict[str, dict[str, int]] | None = None,
    ) -> Directory:
        """A directory of every file (the eval's synthetic world; tests)."""
        d = cls(references=dict(references), iban_links=dict(iban_links or {}))
        tokens: dict[str, set[str]] = {}
        amounts: dict[int, set[str]] = {}
        for a in accounts:
            d.accounts[a.id] = a
            for key in {ref_key(a.external_ref), *(i.key for i in a.items)}:
                if is_lookup_token(key):
                    tokens.setdefault(key, set()).add(a.id)
            for amount in {a.balance_minor, *(i.balance_minor for i in a.items)}:
                if amount > 0:
                    amounts.setdefault(amount, set()).add(a.id)
        d.tokens = {k: frozenset(v) for k, v in tokens.items()}
        d.by_amount = {k: frozenset(v) for k, v in amounts.items() if len(v) <= MAX_PER_AMOUNT}
        return d


MAX_PER_AMOUNT = 20  # an amount shared by more files says nothing (design §8.4: k ≤ 20)


# -- signals --------------------------------------------------------------------------------------

_NOT_ALNUM = re.compile(r"[^0-9A-Za-z]")
_SPLIT = re.compile(r"[\s,;:()\[\]{}<>\"'«»!?*+=&@#|\\]+")
_RUN = re.compile(r"[0-9A-Za-z]+")
_DIGIT = re.compile(r"[0-9]")
# "RF" and two check digits, then up to 21 characters; spaces and line breaks tolerated (design R2).
_RF_HEAD = re.compile(r"(?<![0-9A-Za-z])R\s*F\s*([0-9])\s*([0-9])", re.IGNORECASE)
_BODY_CHAR = re.compile(r"[ \t\r\n]*([0-9A-Za-z])")
_BARE_BODY = re.compile(r"(?<![0-9])([0-9]{4})[ ]?([0-9]{4})[ ]?([0-9]{4})(?![0-9])")
_ISSUED_BODY = 12


def ref_key(text: str) -> str:
    """An invoice or file reference as compared: ASCII letters and digits only, upper case.
    Same as SQL private.ref_key (expression indexes on claim_item.ref, account.external_ref)."""
    return _NOT_ALNUM.sub("", text).upper()


def is_lookup_token(key: str) -> bool:
    return MIN_TOKEN <= len(key) <= MAX_TOKEN and _DIGIT.search(key) is not None


@dataclass(frozen=True, slots=True)
class Signals:
    structured: str | None  # the structured reference, when it is a valid RF
    text_refs: tuple[str, ...]  # valid RFs in the free text (and a structured non-RF reference)
    bodies: tuple[str, ...]  # RFs rebuilt from bare 12-digit bodies
    tokens: tuple[str, ...]  # reference keys looked up across the servicer's files
    short_tokens: frozenset[str]  # keys looked up among the matched file's invoices
    iban: str | None

    def wanted_references(self) -> set[str]:
        return {r for r in (self.structured, *self.text_refs, *self.bodies) if r}


def _texts(p: PaymentIn) -> list[str]:
    out = [p.remittance_text or ""]
    ref = p.creditor_reference
    if ref and not rf_normalise(ref).startswith("RF"):
        out.append(ref)  # a structured reference that is not an RF: read like the free text
    return out


def _rf_candidates(text: str) -> tuple[list[str], str]:
    """Valid RFs written in the text, and the text with every RF-looking span blanked: the digits
    of a reference whose check fails are never read again as a bare body (no guessing)."""
    found: list[str] = []
    blanked = list(text)
    for m in _RF_HEAD.finditer(text):  # heads only: a body never hides the next reference
        head = f"RF{m.group(1)}{m.group(2)}"
        chars: list[str] = []
        ends: list[int] = []
        pos = m.end()
        while len(chars) < 21 and (c := _BODY_CHAR.match(text, pos)) is not None:
            chars.append(c.group(1).upper())
            pos = c.end()
            ends.append(pos)
        # Every length whose check holds (a longer one can hold by chance, 1 in 97): the
        # directory says which, if any, is a reference.
        valid = [n for n in range(len(chars), 0, -1) if rf_valid(head + "".join(chars[:n]))]
        found += [head + "".join(chars[:n]) for n in valid]
        if valid:
            cut = ends[valid[0] - 1]
        else:  # a reference with a wrong check: its issued length is not read again
            cut = ends[min(len(ends), _ISSUED_BODY) - 1] if ends else m.end()
        blanked[m.start() : cut] = " " * (cut - m.start())
    return found, "".join(blanked)


def _tokens(text: str) -> tuple[set[str], set[str]]:
    """Reference keys of a text: each chunk (split on spaces and punctuation that never sits inside
    a reference), its alphanumeric runs, and 2 or 3 consecutive chunks joined ("FA 2026 00042")."""
    chunks = [ref_key(c) for c in _SPLIT.split(text) if c]
    chunks = [c for c in chunks if c]
    keys: set[str] = set(chunks)
    for raw in _SPLIT.split(text):
        keys.update(r.upper() for r in _RUN.findall(raw))
    for n in (2, 3):
        keys.update("".join(chunks[i : i + n]) for i in range(len(chunks) - n + 1))
    lookup = {k for k in keys if is_lookup_token(k)}
    short = {k for k in keys if MIN_DESIGNATION <= len(k) <= MAX_TOKEN and _DIGIT.search(k)}
    return lookup, short


def read_signals(p: PaymentIn) -> Signals:
    structured = None
    if p.creditor_reference:
        ref = rf_normalise(p.creditor_reference)
        structured = ref if rf_valid(ref) else None
    text_refs: list[str] = []
    bodies: list[str] = []
    lookup: set[str] = set()
    short: set[str] = set()
    for text in _texts(p):
        refs, blanked = _rf_candidates(text)
        text_refs += refs
        for m in _BARE_BODY.finditer(blanked):
            bodies.append(rf_make("".join(m.groups())))
        keys, shorts = _tokens(text)
        lookup |= keys
        short |= shorts
    iban = rf_normalise(p.payer_iban) if p.payer_iban else None
    return Signals(
        structured=structured,
        text_refs=tuple(dict.fromkeys(text_refs)),
        bodies=tuple(dict.fromkeys(b for b in bodies if b not in text_refs)),
        tokens=tuple(sorted(lookup)),
        short_tokens=frozenset(short | lookup),
        iban=iban if iban and iban_valid(iban) else None,
    )


# -- names ----------------------------------------------------------------------------------------

# Civil titles, legal forms and joining words: they say nothing about who paid.
NAME_NOISE = frozenset(
    {
        *("M", "MR", "MME", "MLLE", "MM", "MMES", "MRS", "MONSIEUR", "MADAME", "MADEMOISELLE"),
        *("OU", "ET", "DE", "DU", "DES", "LA", "LE", "LES", "CHEZ"),
        *("SAS", "SASU", "SARL", "EURL", "SA", "SCI", "SNC", "SCP", "SELARL", "SELAS", "EI"),
        *("EIRL", "STE", "SOCIETE", "ETS", "ETABLISSEMENTS", "CIE", "GROUPE"),
        *("EPOUX", "EPOUSE", "VEUVE", "VVE"),
    }
)


def name_words(name: str | None) -> tuple[str, ...]:
    """Upper case, accents removed, punctuation as spaces, noise words and initials dropped."""
    if not name:
        return ()
    plain = unicodedata.normalize("NFKD", name)
    plain = "".join(c for c in plain if not unicodedata.combining(c))
    words = _NOT_ALNUM.sub(" ", plain).upper().split()
    return tuple(w for w in words if len(w) > 1 and w not in NAME_NOISE)


def _trigrams(words: Sequence[str]) -> frozenset[str]:
    """pg_trgm's trigrams: each word padded with two spaces before and one after."""
    out: set[str] = set()
    for w in words:
        padded = f"  {w} "
        out.update(padded[i : i + 3] for i in range(len(padded) - 2))
    return frozenset(out)


@lru_cache(maxsize=200_000)
def _name_trigrams(name: str | None) -> frozenset[str]:
    return _trigrams(name_words(name))


def similarity(a: str | None, b: str | None) -> float:
    """Shared trigrams over all trigrams (as pg_trgm's similarity), on the cleaned words."""
    ta, tb = _name_trigrams(a), _name_trigrams(b)
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / len(ta | tb)


def best_similarity(payer: Sequence[str | None], names: Sequence[str]) -> float:
    return max((similarity(p, n) for p in payer if p for n in names), default=0.0)


# -- decisions ------------------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Candidate:
    account_id: str
    rule: str  # the rule that proposed it
    strength: int  # 5 RF, 4 cited reference, 3 IBAN or amount + name, 2 name, 1 amount
    similarity: float
    signals: dict[str, Any]

    def sort_key(self) -> tuple[int, float, str]:
        return (-self.strength, -self.similarity, self.account_id)


@dataclass(frozen=True, slots=True)
class Decision:
    payment_id: str
    rule: str  # R1..R6
    outcome: str  # auto | suggestion | ambiguous | none
    method: str | None = None
    account_id: str | None = None
    designation: tuple[str, ...] = ()  # item ids the payer named (in the matched file)
    evidence: dict[str, Any] = field(default_factory=dict)
    candidates: tuple[Candidate, ...] = ()
    acceptable: bool = False  # the first candidate can be accepted in one tap

    @property
    def automatic(self) -> bool:
        return self.outcome == "auto"

    @property
    def review_reason(self) -> str | None:
        """For a payment left unmatched; an automatic match is gated in SQL."""
        if self.automatic:
            return None
        return "ambiguous" if self.outcome == "ambiguous" else "no_match"

    @property
    def teaches_iban(self) -> bool:
        return self.automatic and self.method in TEACHES_IBAN


class Matcher:
    """Applies the rules to payments in their order (booking date, then statement line)."""

    def __init__(self, directory: Directory) -> None:
        self.d = directory
        self.taken: Counter[str] = Counter()  # matched automatically in this run, per account

    # R1 … R4: a decision, or None to leave the payment to R5/R6.
    def strong(self, p: PaymentIn, s: Signals) -> Decision | None:
        d = self.d
        rf_sources: dict[str, list[tuple[str, str]]] = {}
        sources = [("rf_structured", s.structured)] if s.structured else []
        sources += [("rf_text", r) for r in s.text_refs] + [("rf_body", r) for r in s.bodies]
        for method, ref in sources:
            account = d.references.get(ref)
            if account is not None and account not in p.excluded:
                rf_sources.setdefault(account, []).append((method, ref))
        hits = {
            t: frozenset(a for a in d.tokens.get(t, ()) if a not in p.excluded and a in d.accounts)
            for t in s.tokens
        }
        hits = {t: h for t, h in hits.items() if h}
        if rf_sources:
            return self._by_reference(p, s, rf_sources, hits)
        if hits:
            return self._by_cited_references(p, s, hits)
        return self._by_iban(p, s)

    def _by_reference(
        self,
        p: PaymentIn,
        s: Signals,
        rf_sources: dict[str, list[tuple[str, str]]],
        hits: dict[str, frozenset[str]],
    ) -> Decision:
        """R1/R2. Two files named by references, or a reference and an invoice number that names
        only another file: the payment may be for two files, so ops decide (and may split)."""
        unique_elsewhere = {
            next(iter(h)) for h in hits.values() if len(h) == 1 and next(iter(h)) not in rf_sources
        }
        first_method = min((m for v in rf_sources.values() for m, _ in v), key=AUTO_METHODS.index)
        rule = "R1" if first_method == "rf_structured" else "R2"
        if len(rf_sources) > 1 or unique_elsewhere:
            cands = [
                Candidate(a, rule, 5, self._sim(p, a), {"rf": [r for _, r in v]})
                for a, v in rf_sources.items()
            ]
            cands += [
                Candidate(a, "R3", 4, self._sim(p, a), {"tokens": self._cited(hits, a)})
                for a in unique_elsewhere
            ]
            return self._queue(p, rule, "ambiguous", cands, {"reason": "several_files"})
        account, found = next(iter(rf_sources.items()))
        method = min((m for m, _ in found), key=AUTO_METHODS.index)
        evidence = {"rf": sorted({r for _, r in found}), "source": method}
        return self._auto(p, s, rule, method, account, evidence)

    def _by_cited_references(
        self, p: PaymentIn, s: Signals, hits: dict[str, frozenset[str]]
    ) -> Decision:
        """R3: every cited reference names the same single file, and a second signal backs it."""
        common = frozenset.intersection(*hits.values())
        if len(common) == 1:
            account = next(iter(common))
            info = self.d.accounts[account]
            cited = sorted(hits)
            backing = None if info.closed else self._corroboration(p, s, info, set(cited))
            evidence: dict[str, Any] = {"tokens": cited}
            if backing is not None:
                return self._auto(p, s, "R3", "item_ref", account, {**evidence, **backing})
            why = "account_closed" if info.closed else "not_corroborated"
            signals: dict[str, Any] = {"tokens": cited, "why": why}
            if named := self._designation(s, info):
                signals["designation"] = list(named)  # what ops accept with the suggestion
            cand = Candidate(account, "R3", 4, self._sim(p, account), signals)
            return self._queue(p, "R3", "suggestion", [cand], {"reason": why})
        accounts = sorted({a for h in hits.values() for a in h})
        cands = [
            Candidate(a, "R3", 4, self._sim(p, a), {"tokens": self._cited(hits, a)})
            for a in accounts
        ]
        cands.sort(key=lambda c: (-len(c.signals["tokens"]), *c.sort_key()))
        return self._queue(p, "R3", "ambiguous", cands, {"reason": "reference_in_several_files"})

    def _by_iban(self, p: PaymentIn, s: Signals) -> Decision | None:
        """R4: the payer's IBAN already paid this open file and no other open file."""
        if not s.iban:
            return None
        links = {
            a: n
            for a, n in self.d.iban_links.get(s.iban, {}).items()
            if n >= 1 and a not in p.excluded and a in self.d.accounts and self.d.accounts[a].open
        }
        if not links:
            return None
        if len(links) > 1:
            cands = [
                Candidate(a, "R4", 3, self._sim(p, a), {"iban_payments": str(n)})
                for a, n in links.items()
            ]
            return self._queue(p, "R4", "ambiguous", cands, {"reason": "iban_in_several_files"})
        account, n = next(iter(links.items()))
        info = self.d.accounts[account]
        due = info.balance_minor - info.pending_minor - self.taken[account]
        evidence = {"iban_payments": str(n), "due_minor": str(due)}
        if p.amount_minor <= due:
            return self._auto(p, s, "R4", "iban_memory", account, evidence)
        cand = Candidate(account, "R4", 3, self._sim(p, account), {**evidence, "why": "above_due"})
        return self._queue(p, "R4", "suggestion", [cand], {"reason": "above_due"})

    # R5 / R6: never automatic.
    def weak(self, p: PaymentIn, s: Signals) -> Decision:
        cands: dict[str, Candidate] = {}

        def offer(c: Candidate) -> None:
            if c.account_id in p.excluded or c.account_id not in self.d.accounts:
                return
            old = cands.get(c.account_id)
            if old is None or c.sort_key() < old.sort_key():
                cands[c.account_id] = c

        for a in self.d.by_amount.get(p.amount_minor, ()):
            sim = self._sim(p, a)
            strong = sim >= NAME_SUGGESTS
            offer(
                Candidate(
                    a,
                    "R5" if strong else "R6",
                    3 if strong else 1,
                    sim,
                    {"amount": self._amount_match(p, a), "similarity": f"{sim:.2f}"},
                )
            )
        for a in self.d.by_name.get(p.id, ()):
            sim = self._sim(p, a)
            if sim >= NAME_CORROBORATES:
                offer(Candidate(a, "R6", 2, sim, {"similarity": f"{sim:.2f}"}))
        ranked = sorted(cands.values(), key=Candidate.sort_key)
        rule = "R5" if ranked and ranked[0].rule == "R5" else "R6"
        outcome = "suggestion" if rule == "R5" else "none"
        return self._queue(p, rule, outcome, ranked, {})

    # -- helpers ----------------------------------------------------------------------------------

    def _auto(  # noqa: PLR0913, PLR0917 - a decision is these six facts
        self, p: PaymentIn, s: Signals, rule: str, method: str, account: str, ev: dict[str, Any]
    ) -> Decision:
        info = self.d.accounts.get(account)
        designation = self._designation(s, info) if info else ()
        evidence = {"rule": rule, "method": method, "rule_version": RULE_VERSION, **ev}
        if designation and info:
            refs = {i.id: i.ref for i in info.items}
            evidence["designation"] = [refs[i] for i in designation]
        if p.suggest_only:  # ops decided this payment by hand: suggest, never assign
            sim = self._sim(p, account)
            signals = {**ev, "designation": list(designation)} if designation else ev
            cand = Candidate(account, rule, 5 if rule in ("R1", "R2") else 4, sim, signals)
            return self._queue(p, rule, "suggestion", [cand], {"reason": "decided_by_ops"})
        self.taken[account] += p.amount_minor
        return Decision(p.id, rule, "auto", method, account, designation, evidence)

    def _queue(
        self,
        p: PaymentIn,
        rule: str,
        outcome: str,
        candidates: Sequence[Candidate],
        evidence: dict[str, Any],
    ) -> Decision:
        ranked = (
            sorted(candidates, key=Candidate.sort_key) if outcome != "ambiguous" else candidates
        )
        top = tuple(ranked[:MAX_CANDIDATES])
        first = self.d.accounts.get(top[0].account_id) if top else None
        acceptable = (
            outcome == "suggestion"
            and first is not None
            and first.open
            and (len(ranked) == 1 or ranked[0].sort_key()[:2] < ranked[1].sort_key()[:2])
        )
        return Decision(
            p.id,
            rule,
            outcome,
            evidence={"rule": rule, "rule_version": RULE_VERSION, **evidence},
            candidates=top,
            acceptable=acceptable,
        )

    def _corroboration(
        self, p: PaymentIn, s: Signals, info: AccountInfo, cited: set[str]
    ) -> dict[str, Any] | None:
        if s.iban and self.d.iban_links.get(s.iban, {}).get(info.id, 0) >= 1:
            return {"backed_by": "iban"}
        sim = self._sim(p, info.id)
        if sim >= NAME_CORROBORATES:
            return {"backed_by": "name", "similarity": f"{sim:.2f}"}
        items = [i for i in info.items if i.key in cited]
        if items and p.amount_minor == sum(i.balance_minor for i in items):
            return {"backed_by": "amount_items"}
        if info.balance_minor > 0 and p.amount_minor == info.balance_minor:
            return {"backed_by": "amount_account"}
        return None

    def _designation(self, s: Signals, info: AccountInfo) -> tuple[str, ...]:
        named = s.short_tokens
        return tuple(i.id for i in info.items if i.key and i.key in named)

    def _sim(self, p: PaymentIn, account: str) -> float:
        info = self.d.accounts.get(account)
        if info is None:
            return 0.0
        return best_similarity((p.payer_name, *p.other_names), info.names)

    def _cited(self, hits: dict[str, frozenset[str]], account: str) -> list[str]:
        return sorted(t for t, h in hits.items() if account in h)

    def _amount_match(self, p: PaymentIn, account: str) -> str:
        info = self.d.accounts[account]
        if info.balance_minor == p.amount_minor:
            return "account"
        item = next((i for i in info.items if i.balance_minor == p.amount_minor), None)
        return f"item:{item.ref}" if item else "account"


def match_all(
    payments: Sequence[PaymentIn],
    directory: Directory,
    remainder: Callable[[Sequence[tuple[PaymentIn, Signals]]], None] | None = None,
    signals: Sequence[Signals] | None = None,
) -> list[Decision]:
    """Decisions for payments given in their processing order. `remainder` is called once with the
    payments R1 to R4 left, before R5/R6 run (the job loads amount and name candidates then)."""
    sigs = list(signals) if signals is not None else [read_signals(p) for p in payments]
    matcher = Matcher(directory)
    out: dict[str, Decision] = {}
    rest: list[tuple[PaymentIn, Signals]] = []
    for p, s in zip(payments, sigs, strict=True):
        decision = matcher.strong(p, s)
        if decision is None:
            rest.append((p, s))
        else:
            out[p.id] = decision
    if rest and remainder is not None:
        remainder(rest)
    for p, s in rest:
        out[p.id] = matcher.weak(p, s)
    return [out[p.id] for p in payments]
