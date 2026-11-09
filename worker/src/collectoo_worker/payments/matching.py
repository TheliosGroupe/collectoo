"""Reconciliation (M2-08): which file (account) a payment pays. Deterministic rules, no model.

Design: docs/design/m2b-payments.md §8.4; founder decision #3 (ADR-0013): a payment is matched
automatically only on a valid RF reference, on an invoice or file number backed by the payer's name,
a known IBAN or the exact amount, or on an IBAN that already paid this file and only this one. A
name plus an amount is only a suggestion; the amount alone never is anything.

The rules run in order; a rule only sees the payments the previous ones left (`RULES` below, in
French for ops: the queue shows them). Every decision carries its evidence. Precision first: when
two files are named, nothing is automatic (the payment goes to ops as `ambiguous`); a reference
that fails its check digits is never guessed from, and an RF the payer wrote that names no file of
ours (wrong check digits, another creditor's) stops every automatic match of that payment; a date
(2026-11, 11/2026…) never names a file; the IBAN memory counts every file the IBAN paid, closed
ones and those this statement pays included.

A run decides R1-R3 for every payment first (in processing order), then R4, so the IBAN memory
sees every link the run's own matches teach, whatever the order of the lines. An R3 match backed
by a single word of the payer's name waits for the servicer's name index (the job builds it with
the remainder, after R4), and R4 on that payment's IBAN or file waits for it.

This module is pure: the `payments.match` job loads a `Directory` from the database (only what the
payments' signals need), runs `match_all`, and applies the decisions set-based in SQL, where the
gating of design §8.4 (file not confirmed, closed, held, nothing due…) is decided. The
reconciliation eval runs the same code on a synthetic world
(`collectoo_worker.payments.reconciliation_eval`).
"""

from __future__ import annotations

import re
import unicodedata
from collections import Counter
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass, field, replace
from datetime import date
from functools import lru_cache
from typing import Any

from collectoo_worker.payments.rf import iban_valid, rf_make, rf_normalise, rf_valid

RULE_VERSION = "match-1"
NAME_CORROBORATES = 0.6  # R3: the payer's name backs a cited reference
NAME_SUGGESTS = 0.85  # R5: with the exact amount, a suggestion (never automatic)
# R3: a name sharing a single word with the file backs it only when no other file of the servicer
# has that word: otherwise the debtor of that other file, mistyping a number, could be the payer.
RARE_NAME_FILES = 1
FUZZY_WORD = 5  # a word this long still counts as written with one typo
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
        " jamais devinée ; une référence RF écrite par le payeur qui ne désigne aucun de nos"
        " dossiers (clé fausse, référence inconnue) empêche tout rapprochement automatique.",
    ),
    Rule(
        "R3",
        ("item_ref",),
        True,
        "Numéro de facture ou de dossier confirmé",
        "Le libellé cite des numéros de facture ou de dossier qui désignent tous un seul dossier,"
        " et un autre signal le confirme : IBAN déjà connu pour ce dossier, nom du payeur proche"
        " d'une partie au dossier (60 % au moins, avec deux mots en commun, ou un seul mot"
        " qu'aucun autre dossier ne porte), ou montant égal au solde des factures citées ou du"
        " dossier (pas pour un numéro fait de chiffres seuls). Une date (2026-11, 11/2026…) ne"
        " désigne jamais un dossier. Sans confirmation : simple suggestion.",
    ),
    Rule(
        "R4",
        ("iban_memory",),
        True,
        "IBAN connu",
        "L'IBAN du payeur a déjà payé ce dossier, et aucun autre dossier (même clos, même payé"
        " plus tôt dans ce relevé), et le montant ne dépasse pas ce qui reste dû.",
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
    names: NameIndex | None = None

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
        d.names = NameIndex((a.id, n) for a in d.accounts.values() for n in a.names)
        return d

    def search_names(self, rest: Iterable[PaymentIn]) -> None:
        """Files whose party names are close to each payer's (R6 hints), from the name index."""
        if self.names is None:
            return
        for p in rest:
            found = self.names.search((p.payer_name, *p.other_names))
            if found:
                self.by_name[p.id] = found


MAX_PER_AMOUNT = 20  # an amount shared by more files says nothing (design §8.4: k ≤ 20)
MAX_PER_WORD = 200  # a surname shared by more files is no lead (MARTIN, DUPONT…)
NAME_HINTS = 5


class NameIndex:
    """Files by the words of their parties' names (cleaned as `name_words`): a payer's name finds
    the files sharing a rare enough word, ranked by trigram similarity. Hints for ops only."""

    def __init__(self, pairs: Iterable[tuple[str, str]]) -> None:
        self.names: dict[str, list[str]] = {}
        self.words: dict[str, set[str]] = {}
        for account, name in pairs:
            self.names.setdefault(account, []).append(name)
            for w in name_words(name):
                if len(w) >= 3:
                    self.words.setdefault(w, set()).add(account)

    def files_with(self, word: str) -> int:
        """How many files have a party with this word in its name (words of 3 letters or more)."""
        return len(self.words.get(word, ()))

    def search(self, payer: Sequence[str | None]) -> tuple[str, ...]:
        found: set[str] = set()
        for name in payer:
            for w in name_words(name):
                files = self.words.get(w, ())
                if len(files) <= MAX_PER_WORD:
                    found.update(files)
        scored = [(best_similarity(payer, self.names[a]), a) for a in found]
        best = sorted((s, a) for s, a in scored if s >= NAME_CORROBORATES)
        best.sort(key=lambda x: (-x[0], x[1]))
        return tuple(a for _, a in best[:NAME_HINTS])


# -- signals --------------------------------------------------------------------------------------

_NOT_ALNUM = re.compile(r"[^0-9A-Za-z]")
# Chunks: what is left between characters that never sit inside a reference (only letters,
# digits, - / . _ do), so « n°FA-2026-00042 » or « (FA-2026-00042) » give FA-2026-00042.
_SPLIT = re.compile(r"[^0-9A-Za-z\-/._]+")
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


def _year(digits: str) -> bool:
    return digits[:2] in ("19", "20")


def _month(digits: str) -> bool:
    return "01" <= digits <= "12"


def _day(digits: str) -> bool:
    return "01" <= digits <= "31"


def is_date_digits(digits: str) -> bool:
    """A year, a month or a day written in digits: YYYY, YYYYMM, MMYYYY, YYYYMMDD, DDMMYYYY."""
    if not digits.isascii() or not digits.isdigit():
        return False
    if len(digits) == 4:
        return _year(digits)
    if len(digits) == 6:
        return (_year(digits[:4]) and _month(digits[4:])) or (
            _month(digits[:2]) and _year(digits[2:])
        )
    if len(digits) == 8:
        return (_year(digits[:4]) and _month(digits[4:6]) and _day(digits[6:])) or (
            _day(digits[:2]) and _month(digits[2:4]) and _year(digits[4:])
        )
    return False


def is_lookup_token(key: str) -> bool:
    """A key looked up across the servicer's files: 5 to 35 characters with a digit, and not a
    date (« LOYER 2026-11 » names a month many leases have, never one file: review #1). A date
    still designates the invoices of the file another signal matched (`short_tokens`)."""
    return (
        MIN_TOKEN <= len(key) <= MAX_TOKEN
        and _DIGIT.search(key) is not None
        and not is_date_digits(key)
    )


def is_distinctive(key: str) -> bool:
    """A key that can name a file by itself: letters, and a number that is not a date. A number
    of digits only (or a label and a date, « LOYER202611 ») may be anybody's: the exact amount
    does not back it (R3 needs the payer's name or IBAN)."""
    digits = "".join(_DIGIT.findall(key))
    return digits != key and not is_date_digits(digits)


@dataclass(frozen=True, slots=True)
class Signals:
    structured: str | None  # the structured reference, when it is a valid RF
    text_refs: tuple[str, ...]  # valid RFs in the free text (and a structured non-RF reference)
    bodies: tuple[str, ...]  # RFs rebuilt from bare 12-digit bodies
    tokens: tuple[str, ...]  # reference keys looked up across the servicer's files
    short_tokens: frozenset[str]  # keys looked up among the matched file's invoices
    iban: str | None
    # Every RF the payer wrote (structured, then in the text), as written, with its readings whose
    # check digits hold (none: the check fails at every length).
    rf_written: tuple[tuple[str, tuple[str, ...]], ...] = ()

    def wanted_references(self) -> set[str]:
        return {r for r in (self.structured, *self.text_refs, *self.bodies) if r}

    def unresolved(self, references: Mapping[str, str]) -> tuple[str, ...]:
        """The RFs the payer wrote that name no file of ours (as written, once each): a check that
        fails, or a valid reference of another creditor. The payer named something: no rule may
        then match the payment automatically (review #0, #3)."""
        return tuple(
            dict.fromkeys(
                raw
                for raw, readings in self.rf_written
                if not any(r in references for r in readings)
            )
        )


def _texts(p: PaymentIn) -> list[str]:
    out = [p.remittance_text or ""]
    ref = p.creditor_reference
    if ref and not rf_normalise(ref).startswith("RF"):
        out.append(ref)  # a structured reference that is not an RF: read like the free text
    return out


def _rf_candidates(text: str) -> tuple[list[str], str, list[tuple[str, tuple[str, ...]]]]:
    """Valid RFs written in the text; the text with every RF-looking span blanked (the digits of
    a reference whose check fails are never read again as a bare body: no guessing); and each RF
    as written with its valid readings (none when the check fails at every length)."""
    found: list[str] = []
    written: list[tuple[str, tuple[str, ...]]] = []
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
        readings = [head + "".join(chars[:n]) for n in valid]
        found += readings
        # At least the issued length is never read again (a shorter reading may hold by chance).
        n = max(valid[0] if valid else 0, min(len(ends), _ISSUED_BODY))
        cut = ends[n - 1] if n else m.end()
        blanked[m.start() : cut] = " " * (cut - m.start())
        written.append((" ".join(text[m.start() : cut].split()), tuple(readings)))
    return found, "".join(blanked), written


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
    written: list[tuple[str, tuple[str, ...]]] = []
    if p.creditor_reference:
        ref = rf_normalise(p.creditor_reference)
        structured = ref if rf_valid(ref) else None
        if structured:
            written.append((structured, (structured,)))
        elif ref.startswith("RF"):  # an RF whose check fails
            written.append((" ".join(p.creditor_reference.split()), ()))
    text_refs: list[str] = []
    bodies: list[str] = []
    lookup: set[str] = set()
    short: set[str] = set()
    for text in _texts(p):
        refs, blanked, heads = _rf_candidates(text)
        text_refs += refs
        written += heads
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
        rf_written=tuple(written),
    )


# -- names ----------------------------------------------------------------------------------------

# Civil titles, legal forms and joining words: they say nothing about who paid. Surname particles
# (LE, LA, DE, DU, DES, VAN…) are not noise: they are surnames or parts of one (Lê, Le Roux, De
# Sousa), and dropping them made different people look alike (review #2).
NAME_NOISE = frozenset(
    {
        *("M", "MR", "MME", "MLLE", "MM", "MMES", "MRS", "MONSIEUR", "MADAME", "MADEMOISELLE"),
        *("OU", "ET", "LES", "CHEZ"),
        *("SAS", "SASU", "SARL", "EURL", "SA", "SCI", "SNC", "SCP", "SELARL", "SELAS", "EI"),
        *("EIRL", "STE", "SOCIETE", "ETS", "ETABLISSEMENTS", "CIE", "GROUPE"),
        *("EPOUX", "EPOUSE", "VEUVE", "VVE"),
    }
)
# NFKD leaves ligatures whole (review #5): « CŒUR » would lose its first letters.
_LIGATURES = str.maketrans({"Œ": "OE", "œ": "oe", "Æ": "AE", "æ": "ae", "ß": "ss"})
_ELIDED = frozenset({"D", "L"})  # d', l': elided articles, never initials


@lru_cache(maxsize=200_000)
def name_parts(name: str | None) -> tuple[tuple[str, ...], frozenset[str]]:
    """A name's words and initials: upper case, ligatures written out, accents removed,
    punctuation as spaces, titles, legal forms and joining words dropped (a legal form spelt
    letter by letter, « S.A.R.L. », too). Single letters are initials."""
    if not name:
        return (), frozenset()
    plain = unicodedata.normalize("NFKD", name.translate(_LIGATURES))
    plain = "".join(c for c in plain if not unicodedata.combining(c))
    tokens = [t for t in _NOT_ALNUM.sub(" ", plain).upper().split() if t not in NAME_NOISE]
    words: list[str] = []
    initials: set[str] = set()
    i = 0
    while i < len(tokens):
        j = i
        while j < len(tokens) and len(tokens[j]) == 1:
            j += 1
        if j > i:  # a run of single letters: a legal form spelt out, or initials
            if "".join(tokens[i:j]) not in NAME_NOISE:
                initials.update(t for t in tokens[i:j] if t.isalpha() and t not in _ELIDED)
            i = j
        else:
            words.append(tokens[i])
            i += 1
    return tuple(words), frozenset(initials)


def name_words(name: str | None) -> tuple[str, ...]:
    """The words of a name (see `name_parts`), initials left out."""
    return name_parts(name)[0]


def _initials_fit(initials: frozenset[str], words: Sequence[str], others: frozenset[str]) -> bool:
    """Each initial of one name is the first letter of a word (or an initial) of the other, unless
    the other is a single word (a surname alone, a company): « J DUPONT » is not « Marie
    Dupont »."""
    if not initials or len(words) < 2:
        return True
    return initials <= {w[0] for w in words} | others


def _one_edit(a: str, b: str) -> bool:
    """Equal but for one letter changed, added, dropped, or two neighbours swapped."""
    if a == b:
        return True
    if len(a) == len(b):
        diff = [k for k in range(len(a)) if a[k] != b[k]]
        if len(diff) == 1:
            return True
        i, j = (diff[0], diff[1]) if len(diff) == 2 else (0, 0)
        return j == i + 1 and (a[i], a[j]) == (b[j], b[i])
    if abs(len(a) - len(b)) != 1:
        return False
    short, long = (a, b) if len(a) < len(b) else (b, a)
    k = next((k for k in range(len(short)) if short[k] != long[k]), len(short))
    return short[k:] == long[k + 1 :]


def shared_words(payer: str | None, party: str | None) -> tuple[str, ...]:
    """The party's words the payer wrote: exactly, or with one typo in a word of `FUZZY_WORD`
    letters or more."""
    written = set(name_words(payer))
    out = []
    for w in dict.fromkeys(name_words(party)):
        if w in written or (
            len(w) >= FUZZY_WORD
            and any(abs(len(x) - len(w)) <= 1 and _one_edit(w, x) for x in written)
        ):
            out.append(w)
    return tuple(out)


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
    """Shared trigrams over all trigrams (as pg_trgm's similarity), on the cleaned words; 0 when
    an initial of one name contradicts the other."""
    ta, tb = _name_trigrams(a), _name_trigrams(b)
    if not ta or not tb:
        return 0.0
    (wa, ia), (wb, ib) = name_parts(a), name_parts(b)
    if not (_initials_fit(ia, wb, ib) and _initials_fit(ib, wa, ia)):
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


@dataclass(frozen=True, slots=True)
class Wait:
    """An R3 match the payer's name backs by a single word: final once the name index tells
    whether another file has that word (`Matcher.resolve`)."""

    account: str


class _Later:
    """`_corroboration`: only a single word of the name could back it; the index decides."""


LATER = _Later()


class Matcher:
    """Applies the rules to payments in their order (booking date, then statement line): R1-R3
    for all (`by_reference`), then R4 (`by_iban`), then R5/R6 (`weak`)."""

    def __init__(self, directory: Directory) -> None:
        self.d = directory
        self.taken: Counter[str] = Counter()  # matched automatically in this run, per account
        # IBAN -> {account: n}: what this run's R1-R3 matches teach the IBAN memory. R4 counts
        # them with the stored links, whatever the order of the lines.
        self.run_links: dict[str, Counter[str]] = {}
        # Files and IBANs of R3 decisions waiting for the name index: R4 on them waits too.
        self.held_accounts: set[str] = set()
        self.held_ibans: set[str] = set()

    def hold(self, p: PaymentIn, s: Signals, wait: Wait) -> None:
        if not p.suggest_only:  # one ops decided is never automatic: it changes nothing for R4
            self.held_accounts.add(wait.account)
            if s.iban:
                self.held_ibans.add(s.iban)

    def held(self, p: PaymentIn, s: Signals) -> bool:
        """R4 for this payment depends on a waiting R3 decision (its IBAN, or a file it paid)."""
        if not s.iban:
            return False
        return s.iban in self.held_ibans or any(
            a in self.held_accounts for a in self._linked(p, s.iban)
        )

    # R1 … R3: a decision, a Wait, or None to leave the payment to R4.
    def by_reference(
        self, p: PaymentIn, s: Signals, *, final: bool = False
    ) -> Decision | Wait | None:
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
        unresolved = s.unresolved(d.references)
        if rf_sources:
            return self._by_reference(p, s, rf_sources, hits, unresolved)
        if hits:
            return self._by_cited_references(p, s, hits, unresolved, final=final)
        return None

    def resolve(self, p: PaymentIn, s: Signals) -> Decision:
        """A waiting R3 decision, once the name index is there (or will not be: then the word is
        not known to be rare)."""
        decision = self.by_reference(p, s, final=True)
        assert isinstance(decision, Decision)  # noqa: S101 - same inputs, the name check settled
        return decision

    def _by_reference(
        self,
        p: PaymentIn,
        s: Signals,
        rf_sources: dict[str, list[tuple[str, str]]],
        hits: dict[str, frozenset[str]],
        unresolved: tuple[str, ...],
    ) -> Decision:
        """R1/R2. Two files named by references, or a reference and an invoice number that names
        only another file: the payment may be for two files, so ops decide (and may split). A
        reference that names no file next to the valid one: ops decide too."""
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
            return self._queue(
                p, rule, "ambiguous", cands, {"reason": "several_files"}, unresolved=unresolved
            )
        account, found = next(iter(rf_sources.items()))
        method = min((m for m, _ in found), key=AUTO_METHODS.index)
        evidence = {"rf": sorted({r for _, r in found}), "source": method}
        if unresolved:
            return self._unresolved(p, rule, account, 5, evidence, unresolved)
        return self._auto(p, s, rule, method, account, evidence)

    def _by_cited_references(
        self,
        p: PaymentIn,
        s: Signals,
        hits: dict[str, frozenset[str]],
        unresolved: tuple[str, ...],
        *,
        final: bool,
    ) -> Decision | Wait:
        """R3: every cited reference names the same single file, and a second signal backs it."""
        common = frozenset.intersection(*hits.values())
        if len(common) == 1:
            account = next(iter(common))
            info = self.d.accounts[account]
            cited = sorted(hits)
            evidence: dict[str, Any] = {"tokens": cited}
            if unresolved and not info.closed:
                return self._unresolved(p, "R3", account, 4, evidence, unresolved)
            backing = None if info.closed else self._corroboration(p, s, info, cited, final=final)
            if isinstance(backing, _Later):
                return Wait(account)
            if backing is not None:
                return self._auto(p, s, "R3", "item_ref", account, {**evidence, **backing})
            why = "account_closed" if info.closed else "not_corroborated"
            signals: dict[str, Any] = {"tokens": cited, "why": why}
            if named := self._designation(s, info):
                signals["designation"] = list(named)  # what ops accept with the suggestion
            cand = Candidate(account, "R3", 4, self._sim(p, account), signals)
            return self._queue(
                p, "R3", "suggestion", [cand], {"reason": why}, unresolved=unresolved
            )
        accounts = sorted({a for h in hits.values() for a in h})
        cands = [
            Candidate(a, "R3", 4, self._sim(p, a), {"tokens": self._cited(hits, a)})
            for a in accounts
        ]
        cands.sort(key=lambda c: (-len(c.signals["tokens"]), *c.sort_key()))
        return self._queue(
            p,
            "R3",
            "ambiguous",
            cands,
            {"reason": "reference_in_several_files"},
            unresolved=unresolved,
        )

    def by_iban(self, p: PaymentIn, s: Signals) -> Decision | None:  # noqa: PLR0911
        """R4: the payer's IBAN paid this open file and no other file: none stored (closed files
        included, review #4) and none this run's R1-R3 matches pay (review #11)."""
        if not s.iban:
            return None
        linked = self._linked(p, s.iban)
        if not linked:
            return None
        unresolved = s.unresolved(self.d.references)
        if len(linked) > 1:
            cands = [
                Candidate(a, "R4", 3, self._sim(p, a), {"iban_payments": str(n)})
                for a, n in linked.items()
                if a in self.d.accounts
            ]
            cands.sort(key=Candidate.sort_key)
            evidence = {"reason": "iban_in_several_files"}
            return self._queue(p, "R4", "ambiguous", cands, evidence, unresolved=unresolved)
        account, n = next(iter(linked.items()))
        info = self.d.accounts.get(account)
        if info is None or not info.open:  # it paid only a closed or unconfirmed file: R5/R6
            return None
        due = info.balance_minor - info.pending_minor - self.taken[account]
        evidence = {"iban_payments": str(n), "due_minor": str(due)}
        if unresolved:
            return self._unresolved(p, "R4", account, 3, evidence, unresolved)
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
        return self._queue(p, rule, outcome, ranked, {}, unresolved=s.unresolved(self.d.references))

    # -- helpers ----------------------------------------------------------------------------------

    def _auto(  # noqa: PLR0913, PLR0917 - a decision is these six facts
        self,
        p: PaymentIn,
        s: Signals,
        rule: str,
        method: str,
        account: str,
        ev: dict[str, Any],
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
        if method in TEACHES_IBAN and s.iban:
            self.run_links.setdefault(s.iban, Counter())[account] += 1
        return Decision(p.id, rule, "auto", method, account, designation, evidence)

    def _linked(self, p: PaymentIn, iban: str) -> dict[str, int]:
        """Every file the IBAN paid (n ≥ 1), stored or matched in this run, whatever its status,
        except those ops took this payment away from."""
        links: Counter[str] = Counter(self.d.iban_links.get(iban, {}))
        links.update(self.run_links.get(iban, {}))
        return {a: n for a, n in links.items() if n >= 1 and a not in p.excluded}

    def _unresolved(  # noqa: PLR0913, PLR0917 - the file a rule names and what blocks it
        self,
        p: PaymentIn,
        rule: str,
        account: str,
        strength: int,
        evidence: dict[str, Any],
        unresolved: tuple[str, ...],
    ) -> Decision:
        """A rule names one file, but the payer also wrote a reference that names none of ours:
        a suggestion ops must look at (never one tap), the reference as written in front of them."""
        signals = {**evidence, "why": "unresolved_reference"}
        cand = Candidate(account, rule, strength, self._sim(p, account), signals)
        reason = {"reason": "unresolved_reference"}
        return self._queue(
            p, rule, "suggestion", [cand], reason, unresolved=unresolved, one_tap=False
        )

    def _queue(  # noqa: PLR0913 - a queued decision and what ops see with it
        self,
        p: PaymentIn,
        rule: str,
        outcome: str,
        candidates: Sequence[Candidate],
        evidence: dict[str, Any],
        *,
        unresolved: tuple[str, ...] = (),
        one_tap: bool = True,
    ) -> Decision:
        if unresolved:  # shown with every candidate: only their signals reach the queue
            evidence = {**evidence, "unresolved": list(unresolved)}
            candidates = [
                replace(c, signals={**c.signals, "unresolved": list(unresolved)})
                for c in candidates
            ]
        ranked = (
            sorted(candidates, key=Candidate.sort_key) if outcome != "ambiguous" else candidates
        )
        top = tuple(ranked[:MAX_CANDIDATES])
        first = self.d.accounts.get(top[0].account_id) if top else None
        acceptable = (
            one_tap
            and outcome == "suggestion"
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

    def _corroboration(  # noqa: PLR0911 - one return per backing
        self, p: PaymentIn, s: Signals, info: AccountInfo, cited: Sequence[str], *, final: bool
    ) -> dict[str, Any] | _Later | None:
        """R3's second signal: the IBAN memory, the payer's name (two shared words, or one that
        no other file has), or the exact amount of the cited invoices or of the file (not for a
        number made of digits only, or of a label and a date)."""
        if s.iban and self.d.iban_links.get(s.iban, {}).get(info.id, 0) >= 1:
            return {"backed_by": "iban"}
        two, single = self._name_overlap(p, info)
        if two is not None:
            return {"backed_by": "name", "similarity": f"{two:.2f}"}
        if any(is_distinctive(k) for k in cited):
            named = set(self._designation(s, info))
            items = [i for i in info.items if i.id in named]
            if items and p.amount_minor == sum(i.balance_minor for i in items):
                return {"backed_by": "amount_items"}
            if info.balance_minor > 0 and p.amount_minor == info.balance_minor:
                return {"backed_by": "amount_account"}
        if not single:
            return None
        if not final:
            return LATER
        index = self.d.names
        rare = [
            (sim, w)
            for sim, w in single
            if index is not None and len(w) >= 3 and index.files_with(w) <= RARE_NAME_FILES
        ]
        if not rare:
            return None
        sim, word = max(rare)
        return {"backed_by": "name", "similarity": f"{sim:.2f}", "rare_word": word}

    def _name_overlap(
        self, p: PaymentIn, info: AccountInfo
    ) -> tuple[float | None, list[tuple[float, str]]]:
        """The best similarity (≥ 0.6) of a payer's name and a party's sharing two words or more,
        and the (similarity, word) of those sharing a single word, written exactly (a word one
        letter away, « MARTINS » for « Martin », may be another file's debtor's own name)."""
        two: float | None = None
        single: list[tuple[float, str]] = []
        for payer in (p.payer_name, *p.other_names):
            for party in info.names:
                sim = similarity(payer, party)
                if sim < NAME_CORROBORATES:
                    continue
                shared = shared_words(payer, party)
                if len(shared) >= 2:
                    two = max(two or 0.0, sim)
                elif shared and shared[0] in name_words(payer):  # written exactly: see above
                    single.append((sim, shared[0]))
        return two, single

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


_Pairs = list[tuple[PaymentIn, Signals]]


def _by_references(
    matcher: Matcher, pairs: Sequence[tuple[PaymentIn, Signals]], out: dict[str, Decision]
) -> tuple[_Pairs, _Pairs]:
    """R1-R3 for every payment: decisions into `out`; returns the waiting ones and the rest."""
    waiting: _Pairs = []
    later: _Pairs = []
    for p, s in pairs:
        decision = matcher.by_reference(p, s)
        if isinstance(decision, Decision):
            out[p.id] = decision
        elif isinstance(decision, Wait):
            waiting.append((p, s))
            matcher.hold(p, s, decision)
        else:
            later.append((p, s))
    return waiting, later


def match_all(
    payments: Sequence[PaymentIn],
    directory: Directory,
    remainder: Callable[[Sequence[tuple[PaymentIn, Signals]]], None] | None = None,
    signals: Sequence[Signals] | None = None,
) -> list[Decision]:
    """Decisions for payments given in their processing order: R1-R3 for every payment, then R4
    (it sees every IBAN link the run's R1-R3 matches teach, before or after in the order), then
    R5/R6. An R3 decision resting on a single word of the payer's name waits for the name index,
    and R4 decisions on its IBAN or its file wait for it. `remainder` is called once, before
    those and R5/R6, with the payments R1 to R4 left and the waiting ones (the job then loads the
    amount and name candidates, and the servicer's name index)."""
    pairs = list(
        zip(
            payments,
            list(signals) if signals is not None else map(read_signals, payments),
            strict=True,
        )
    )
    matcher = Matcher(directory)
    out: dict[str, Decision] = {}
    waiting, later = _by_references(matcher, pairs, out)
    rest: list[tuple[PaymentIn, Signals]] = []
    held: list[tuple[PaymentIn, Signals]] = []
    for p, s in later:
        if matcher.held(p, s):
            held.append((p, s))
        elif (found := matcher.by_iban(p, s)) is not None:
            out[p.id] = found
        else:
            rest.append((p, s))
    asked = {p.id for p, _ in (*rest, *waiting, *held)}
    if asked and remainder is not None:
        remainder([(p, s) for p, s in pairs if p.id in asked])
    for p, s in waiting:
        out[p.id] = matcher.resolve(p, s)
    for p, s in held:
        if (found := matcher.by_iban(p, s)) is not None:
            out[p.id] = found
        else:
            rest.append((p, s))
    if rest and remainder is None:
        directory.search_names(p for p, _ in rest)
    for p, s in rest:
        out[p.id] = matcher.weak(p, s)
    return [out[p.id] for p in payments]
