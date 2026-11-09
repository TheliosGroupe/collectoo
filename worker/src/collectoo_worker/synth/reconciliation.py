"""Synthetic reconciliation world and bank credits with a ground truth (M2-08; founder decision
#19: synthetic files only until anonymised real exports arrive).

A `World` is a servicer's files as matching sees them: references (RF), invoice, lease and loan
numbers, parties, open balances, and the IBANs that already paid a file. `generate_credits` writes
bank credits that pay them, each with its truth: the file it pays (or none) and what matching must
do with it (`auto`, or the queue with the reason ops will see). The mix follows design §13:

- 45 % structured RF (`CdtrRefInf`), the payer being the debtor or a third party;
- 25 % RF in the free text: grouped by four, lower case, glued, split over two lines;
- 5 % the 12 digits of the reference alone;
- 15 % invoice, lease or loan numbers, backed by the payer's name (titles, word order, case, a
  typo) or, for a third party, by the exact balance of the invoices cited;
- 6 % no reference, from an IBAN that already paid that file and no other;
- 4 % deliberately unmatchable: name and amount only, an RF with one wrong digit or two digits
  swapped, no information at all, an invoice number two files share, an IBAN that paid two files.

Every name, IBAN and reference is synthetic (Faker fr_FR; valid check digits; random digits).
"""

from __future__ import annotations

import hashlib
import random
import string
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Any

from faker import Faker

from collectoo_worker.payments.matching import (
    AccountInfo,
    Directory,
    ItemInfo,
    PaymentIn,
    is_lookup_token,
    ref_key,
)
from collectoo_worker.payments.rf import rf_format, rf_make
from collectoo_worker.synth.camt053 import Entry, Tx
from collectoo_worker.synth.ids import iban_fr

MIX: tuple[tuple[str, float], ...] = (
    ("rf_structured", 0.45),
    ("rf_text", 0.25),
    ("rf_body", 0.05),
    ("item_ref", 0.15),
    ("repeat_iban", 0.06),
    ("name_amount", 0.01),
    ("rf_typo", 0.01),
    ("no_info", 0.008),
    ("shared_ref", 0.007),
    ("iban_two_files", 0.005),
)
EXPECT = {
    "rf_structured": "auto",
    "rf_text": "auto",
    "rf_body": "auto",
    "item_ref": "auto",
    "repeat_iban": "auto",
    "name_amount": "no_match",
    "rf_typo": "no_match",
    "no_info": "no_match",
    "shared_ref": "ambiguous",
    "iban_two_files": "ambiguous",
}
OPEN = ("awaiting_first_letter", "in_collection", "arrangement", "legal")


@dataclass(frozen=True)
class WorldAccount:
    id: str
    external_ref: str
    kind: str  # invoice | rent | loan
    status: str
    rf: str | None
    names: tuple[str, ...]
    items: tuple[ItemInfo, ...]
    currency: str = "EUR"

    @property
    def balance_minor(self) -> int:
        return sum(i.balance_minor for i in self.items)

    def info(self) -> AccountInfo:
        return AccountInfo(
            self.id,
            self.external_ref,
            self.status,
            self.currency,
            self.names,
            self.items,
            self.balance_minor,
        )


@dataclass
class World:
    accounts: list[WorldAccount]
    iban_links: dict[str, dict[str, int]] = field(default_factory=dict)  # earlier payments

    def directory(self) -> Directory:
        refs = {a.rf: a.id for a in self.accounts if a.rf}
        return Directory.build((a.info() for a in self.accounts), refs, self.iban_links)

    def by_id(self) -> dict[str, WorldAccount]:
        return {a.id: a for a in self.accounts}


def debtor_iban(account_id: str) -> str:
    """The IBAN a file's debtor pays from (deterministic per file)."""
    return iban_fr(random.Random(f"debtor-iban:{account_id}"))


def _id(seed: int, n: int) -> str:
    h = hashlib.sha256(f"world:{seed}:{n}".encode()).hexdigest()
    return f"{h[:8]}-{h[8:12]}-4{h[13:16]}-8{h[17:20]}-{h[20:32]}"


@dataclass
class _Books:
    """Generators of one world: random draws and the invoice numbers already used."""

    rng: random.Random
    fake: Faker
    seed: int
    martin_refs: list[str] = field(default_factory=list)

    def item(self, n: int, j: int, ref: str, balance: int) -> ItemInfo:
        return ItemInfo(_id(self.seed + 1, n * 8 + j), ref, balance)

    def invoices(self, n: int) -> tuple[str, str, tuple[str, ...], list[ItemInfo]]:
        """Two invoicing styles; 2 % of the second client's numbers are also the first's."""
        martin = self.rng.random() < 0.6
        items = []
        for j in range(self.rng.randint(1, 4)):
            if martin:
                ref = f"FA-2026-{len(self.martin_refs) + 1:05d}"
                self.martin_refs.append(ref)
            elif self.martin_refs and self.rng.random() < 0.02:
                ref = self.rng.choice(self.martin_refs)  # the same number in two clients' books
            else:
                ref = f"DB/26/{n:06d}-{j + 1}"
            items.append(self.item(n, j, ref, self.rng.randint(5_000, 900_000)))
        ext = f"MART-{n:06d}" if martin else f"DUB{n:07d}"
        return "invoice", ext, (self.fake.company(),), items

    def lease(self, n: int) -> tuple[str, str, tuple[str, ...], list[ItemInfo]]:
        names: tuple[str, ...] = (f"{self.fake.last_name().upper()} {self.fake.first_name()}",)
        if self.rng.random() < 0.3:
            names += (f"{self.fake.last_name().upper()} {self.fake.first_name()}",)
        rent = self.rng.randint(45_000, 180_000)
        months = self.rng.sample(range(5, 11), self.rng.randint(1, 4))
        items = [self.item(n, j, f"2026-{m:02d}", rent) for j, m in enumerate(months)]
        return "rent", f"BAIL-{n:06d}", names, items

    def loan(self, n: int) -> tuple[str, str, tuple[str, ...], list[ItemInfo]]:
        """The item is the loan, numbered like the file."""
        names: tuple[str, ...] = (self.fake.name(),)
        if self.rng.random() < 0.15:
            names += (self.fake.name(),)
        ext = f"CC2025{n:06d}"
        return "loan", ext, names, [self.item(n, 0, ext, self.rng.randint(50_000, 2_500_000))]


def synthetic_world(accounts: int, seed: int = 1) -> World:
    """Files of three clients: B2B invoices (two invoicing styles), rent, consumer loans. A few
    invoice numbers are shared by two clients' files; a quarter of the debtors already paid from
    their IBAN (the IBAN memory); a few IBANs paid two files (a parent paying for two children)."""
    rng = random.Random(seed)
    fake = Faker("fr_FR")
    fake.seed_instance(seed)
    books = _Books(rng, fake, seed)
    out: list[WorldAccount] = []
    bodies: set[str] = set()
    for n in range(accounts):
        roll = rng.random()
        make = books.invoices if roll < 0.4 else books.lease if roll < 0.65 else books.loan
        kind, ext, names, items = make(n)
        closed = rng.random() < 0.02
        if closed:
            items = [ItemInfo(i.id, i.ref, 0) for i in items]
        body = f"{rng.randrange(10**12):012d}"
        while body in bodies:
            body = f"{rng.randrange(10**12):012d}"
        bodies.add(body)
        status = "closed_paid" if closed else rng.choice(OPEN)
        out.append(
            WorldAccount(_id(seed, n), ext, kind, status, rf_make(body), names, tuple(items))
        )
    return with_history(World(out), rng)


def with_history(world: World, rng: random.Random) -> World:
    """The IBAN memory of a world: a quarter of the open files' debtors already paid from their
    IBAN; 1 % of IBANs paid two files (a parent paying for two children)."""
    open_ = [a for a in world.accounts if a.status in OPEN and a.balance_minor > 0]
    links: dict[str, dict[str, int]] = {}
    for a in rng.sample(open_, len(open_) // 4):
        links[debtor_iban(a.id)] = {a.id: rng.randint(1, 3)}
    for _ in range(max(1, len(open_) // 100) if len(open_) >= 2 else 0):
        a, b = rng.sample(open_, 2)
        links[iban_fr(rng)] = {a.id: 1, b.id: 1}
    return World(world.accounts, links)


# -- credits --------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Credit:
    """One bank credit and its ground truth."""

    amount_minor: int
    name: str | None
    iban: str | None
    ustrd: tuple[str, ...]
    creditor_ref: str | None
    truth: str | None  # the file it pays; None: nobody can tell
    expect: str  # auto | no_match | ambiguous
    scenario: str
    ultimate_name: str | None = None

    def payment(self, pid: str, booking: date, currency: str = "EUR") -> PaymentIn:
        """As the import would store it (free text lines joined by line breaks)."""
        return PaymentIn(
            id=pid,
            amount_minor=self.amount_minor,
            currency=currency,
            booking_date=booking,
            payer_name=self.name or self.ultimate_name,
            payer_iban=self.iban,
            remittance_text="\n".join(self.ustrd) or None,
            creditor_reference=self.creditor_ref,
            other_names=(self.ultimate_name,) if self.name and self.ultimate_name else (),
        )


@dataclass
class _Pools:
    """Which files each scenario may pay, so that its expectation holds by construction."""

    world: World
    open_: list[WorldAccount]
    single_link: list[tuple[WorldAccount, str]]  # a file and the IBAN that paid it (only it)
    two_files: list[tuple[str, list[str]]]
    unique_items: list[tuple[WorldAccount, ItemInfo]]
    shared_items: list[tuple[WorldAccount, ItemInfo]]
    linked_ibans: set[str]

    @classmethod
    def of(cls, world: World) -> _Pools:
        open_ = [a for a in world.accounts if a.status in OPEN and a.balance_minor > 0 and a.rf]
        owners: dict[str, set[str]] = {}
        for a in world.accounts:
            for key in {ref_key(a.external_ref), *(i.key for i in a.items)}:
                owners.setdefault(key, set()).add(a.id)
        ids = {a.id for a in open_}
        files = world.by_id()
        by_iban = [(iban, links) for iban, links in world.iban_links.items()]
        single = [
            (files[account], iban)
            for iban, links in by_iban
            for account, n in links.items()
            if len(links) == 1 and n >= 1 and account in ids
        ]
        single.sort(key=lambda x: x[0].external_ref)
        # files in the order of their references (ids are drawn afresh in each database)
        two = [
            (iban, sorted(links, key=lambda a: files[a].external_ref))
            for iban, links in by_iban
            if len(links) == 2 and set(links) <= ids
        ]
        two.sort(key=lambda x: [files[a].external_ref for a in x[1]])
        unique, shared = [], []
        for a in open_:
            for i in a.items:
                if i.balance_minor <= 0 or not is_lookup_token(i.key):
                    continue
                if owners[i.key] == {a.id} and owners.get(ref_key(a.external_ref)) == {a.id}:
                    unique.append((a, i))
                elif len(owners[i.key]) == 2 and owners[i.key] <= ids:
                    shared.append((a, i))
        return cls(world, open_, single, two, unique, shared, set(world.iban_links))


class _Writer:
    def __init__(self, world: World, seed: int, earlier: Sequence[Credit] = ()) -> None:
        self.rng = random.Random(seed)
        self.fake = Faker("fr_FR")
        self.fake.seed_instance(seed)
        self.p = _Pools.of(world)
        self.taken: dict[str, int] = {}  # paid to each file (earlier statements included)
        for c in earlier:
            if c.truth is not None:
                self.taken[c.truth] = self.taken.get(c.truth, 0) + c.amount_minor

    def left(self, a: WorldAccount) -> int:
        return a.balance_minor - self.taken.get(a.id, 0)

    def pick(self, pool: Sequence[Any], file: Any = lambda x: x) -> Any:
        """A file of the pool that still owes something (payers do not pay a settled file)."""
        for _ in range(30):
            choice = self.rng.choice(pool)
            a = file(choice)
            if self.left(a) >= max(1_000, a.balance_minor // 10):
                return choice
        return self.rng.choice(pool)

    # -- payers ---------------------------------------------------------------------------------

    def fresh_iban(self) -> str:
        while True:
            iban = iban_fr(self.rng)
            if iban not in self.p.linked_ibans:
                return iban

    def stranger(self) -> str:
        return self.fake.company() if self.rng.random() < 0.3 else self.fake.name()

    def as_payer(self, name: str, typo: bool = True) -> str:
        """How a bank prints a debtor's name: case, titles, word order, sometimes one typo."""
        rng = self.rng
        words = name.split()
        style = rng.randrange(6)
        if style == 0:
            out = name.upper()
        elif style == 1 and len(words) >= 2:
            out = " ".join(reversed(words)).upper()
        elif style == 2:
            out = f"M OU MME {name.upper()}"
        elif style == 3 and typo:
            long = [i for i, w in enumerate(words) if len(w) >= 7 and w.isalpha()]
            if long:
                i = rng.choice(long)
                w = words[i]
                k = rng.randrange(1, len(w) - 1)
                words[i] = w[:k] + rng.choice(string.ascii_uppercase) + w[k + 1 :]
            out = " ".join(words).upper()
        else:
            out = name
        return out[:70]

    def amount(self, a: WorldAccount, *, share: float = 0.3) -> int:
        """A partial payment that leaves room for the file's other payments in the statement."""
        top = max(1, int(max(self.left(a), 0) * share))
        amount = self.rng.randint(min(100, top), top)
        self.taken[a.id] = self.taken.get(a.id, 0) + amount
        return amount

    # -- scenarios ------------------------------------------------------------------------------

    def credit(self, scenario: str) -> Credit:
        """A credit of that scenario (one with an empty pool pays by structured RF instead)."""
        if scenario in ("rf_structured", "rf_text", "rf_body"):
            return self._by_reference(scenario, self.pick(self.p.open_))
        if scenario == "item_ref" and self.p.unique_items:
            return self._by_invoice(*self.pick(self.p.unique_items, lambda x: x[0]))
        write = {
            "repeat_iban": self._repeat_iban if self.p.single_link else None,
            "name_amount": self._name_amount,
            "rf_typo": self._rf_typo,
            "shared_ref": self._shared_ref if self.p.shared_items else None,
            "iban_two_files": self._iban_two_files if self.p.two_files else None,
            "no_info": self._no_info,
        }.get(scenario)
        if write is not None:
            return write()
        return self._by_reference("rf_structured", self.pick(self.p.open_))

    def _repeat_iban(self) -> Credit:
        a, iban = self.pick(self.p.single_link, lambda x: x[0])
        text = self.rng.choice(((), ("VIREMENT",), ("Remboursement mensuel",), ("ECHEANCE",)))
        amount = self.amount(a, share=0.1)
        name = self.as_payer(a.names[0])
        return Credit(amount, name, iban, text, None, a.id, "auto", "repeat_iban")

    def _name_amount(self) -> Credit:
        a = self.rng.choice(self.p.open_)
        item = self.rng.choice(a.items)
        whole = self.rng.random() < 0.5 or item.balance_minor <= 0
        amount = a.balance_minor if whole else item.balance_minor
        iban = self.fresh_iban()
        return Credit(amount, a.names[0], iban, ("SOLDE",), None, a.id, "no_match", "name_amount")

    def _rf_typo(self) -> Credit:
        a = self.pick(self.p.open_)
        bad = _typo(a.rf or "", self.rng)
        structured = self.rng.random() < 0.5
        text = () if structured else (f"REGLT {rf_format(bad)}",)
        amount, iban = self.amount(a, share=0.1), self.fresh_iban()
        ref = bad if structured else None
        return Credit(amount, self.stranger(), iban, text, ref, a.id, "no_match", "rf_typo")

    def _shared_ref(self) -> Credit:
        a, item = self.pick(self.p.shared_items, lambda x: x[0])
        text = (f"REGLEMENT FACTURE {item.ref}",)
        amount, iban = self.amount(a, share=0.1), self.fresh_iban()
        return Credit(amount, self.stranger(), iban, text, None, a.id, "ambiguous", "shared_ref")

    def _iban_two_files(self) -> Credit:
        iban, files = self.rng.choice(self.p.two_files)
        a = self.p.world.by_id()[self.rng.choice(files)]
        amount = self.amount(a, share=0.05)
        name = self.stranger()
        return Credit(amount, name, iban, ("VIREMENT",), None, a.id, "ambiguous", "iban_two_files")

    def _no_info(self) -> Credit:
        text = self.rng.choice(((), ("VIREMENT",), ("CADEAU",), ("REMBOURSEMENT",)))
        amount, iban = self.rng.randint(1_000, 50_000), self.fresh_iban()
        return Credit(amount, self.stranger(), iban, text, None, None, "no_match", "no_info")

    def _payer(self, a: WorldAccount) -> tuple[str, str]:
        """The debtor (from their IBAN, or a new one) or, one time in four, a third party."""
        if self.rng.random() < 0.25:
            return self.stranger(), self.fresh_iban()
        name = self.as_payer(self.rng.choice(a.names))
        return name, debtor_iban(a.id)

    def _by_reference(self, scenario: str, a: WorldAccount) -> Credit:
        rng = self.rng
        rf = a.rf or ""
        name, iban = self._payer(a)
        creditor_ref = None
        own = rng.choice(a.items).ref
        if scenario == "rf_structured":
            creditor_ref = rf if rng.random() < 0.7 else rf_format(rf)
            text: tuple[str, ...] = rng.choice(((), (f"Facture {own}",), ("REGLEMENT DOSSIER",)))
        elif scenario == "rf_text":
            g = rf_format(rf)
            text = rng.choice(
                (
                    (f"REGLT {g}",),
                    (f"paiement {rf.lower()} merci",),
                    (f"VIR {g[:9]}", g[10:]),
                    (f"Ref {rf} {own}",),
                    (f"Votre reference {g.lower()} - echeance",),
                )
            )
        else:
            body = rf[4:]
            grouped = f"{body[:4]} {body[4:8]} {body[8:]}"
            text = rng.choice(((f"REF {grouped}",), (f"PAIEMENT {body}",), (f"Dossier {grouped}",)))
        return Credit(self.amount(a), name, iban, text, creditor_ref, a.id, "auto", scenario)

    def _by_invoice(self, a: WorldAccount, item: ItemInfo) -> Credit:
        rng = self.rng
        if a.kind == "rent":
            text: tuple[str, ...] = rng.choice(
                ((f"LOYER {item.ref} {a.external_ref}",), (f"Loyer bail {a.external_ref}",))
            )
        elif a.kind == "loan":
            text = rng.choice(
                ((f"ECHEANCE PRET {item.ref}",), (f"Remboursement credit n°{item.ref}",))
            )
        else:
            text = rng.choice(((f"REGLT FACT {item.ref}",), (f"VIR FACTURE N {item.ref}",)))
        if rng.random() < 0.2 and self.taken.get(a.id, 0) == 0:  # a third party pays it to the cent
            self.taken[a.id] = self.taken.get(a.id, 0) + item.balance_minor
            return Credit(
                item.balance_minor,
                self.stranger(),
                self.fresh_iban(),
                text,
                None,
                a.id,
                "auto",
                "item_ref",
            )
        name = self.as_payer(rng.choice(a.names))
        return Credit(self.amount(a), name, self.fresh_iban(), text, None, a.id, "auto", "item_ref")


def _typo(rf: str, rng: random.Random) -> str:
    """One digit replaced, or two adjacent digits swapped, in the 14 digits after "RF"."""
    digits = list(rf[2:])
    i = rng.randrange(len(digits) - 1)
    if rng.random() < 0.5 and digits[i] != digits[i + 1]:
        digits[i], digits[i + 1] = digits[i + 1], digits[i]
    else:
        digits[i] = rng.choice([d for d in string.digits if d != digits[i]])
    return "RF" + "".join(digits)


def mix_counts(n: int) -> dict[str, int]:
    """Credits per scenario: exactly the mix (largest remainders), whatever the sample size."""
    exact = {name: n * weight for name, weight in MIX}
    counts = {name: int(x) for name, x in exact.items()}
    by_remainder = sorted(MIX, key=lambda m: (-(exact[m[0]] - counts[m[0]]), m[0]))
    for name, _ in by_remainder[: n - sum(counts.values())]:
        counts[name] += 1
    return counts


def generate_credits(
    world: World, n: int, seed: int = 1, earlier: Sequence[Credit] = ()
) -> list[Credit]:
    """n credits in the mix's exact proportions, in a random order. `earlier`: credits already
    paid to the files (an earlier statement): nobody pays a file more than it still owes."""
    w = _Writer(world, seed, earlier)
    scenarios = [name for name, k in mix_counts(n).items() for _ in range(k)]
    w.rng.shuffle(scenarios)
    return [w.credit(s) for s in scenarios]


def history_credits(world: World, seed: int = 1) -> list[Credit]:
    """The earlier payments behind the world's IBAN memory: one per (IBAN, file) it knows, by
    structured RF from that IBAN (what teaches the memory through the database)."""
    rng = random.Random(seed)
    files = world.by_id()
    out = []
    # in the order of the files' references (not of ids or IBANs, drawn afresh in each database)
    order = sorted(
        world.iban_links.items(), key=lambda kv: sorted(files[a].external_ref for a in kv[1])
    )
    for iban, links in order:
        for account in sorted(links):
            a = files[account]
            amount = rng.randint(100, max(100, a.balance_minor // 20))
            out.append(Credit(amount, a.names[0], iban, (), a.rf, a.id, "auto", "history"))
    return out


def line_ref(prefix: str, k: int) -> str:
    """The bank's reference of the k-th credit of a statement (`TxDtls/Refs/AcctSvcrRef`)."""
    return f"{prefix}{k:012d}"


def credit_entries(
    credits: Sequence[Credit], *, start: date, days: int = 1, prefix: str = "TX"
) -> list[Entry]:
    """One booked camt.053 entry per credit, its line referenced `line_ref(prefix, k)` (k from 1;
    another prefix per statement), the truth carried by the Tx."""
    out = []
    for k, c in enumerate(credits, start=1):
        day = start + timedelta(days=k * days // (len(credits) + 1))
        tx = Tx(
            c.amount_minor,
            ref=line_ref(prefix, k),
            end_to_end_id=f"E2E{prefix}{k:012d}" if k % 3 else None,
            name=c.name,
            iban=c.iban,
            ultimate_name=c.ultimate_name,
            ustrd=c.ustrd,
            creditor_ref=c.creditor_ref,
            truth=c.truth,
            expect=c.expect,
            scenario=c.scenario,
        )
        out.append(Entry(c.amount_minor, True, day, day, ref=f"N{prefix}{k:012d}", txs=(tx,)))
    return out


# -- scoring --------------------------------------------------------------------------------------


@dataclass
class Score:
    """Auto-match rate, wrong automatic matches, and the queue against the truth."""

    total: int = 0
    auto: int = 0
    wrong: list[str] = field(default_factory=list)
    queued: int = 0
    missed: dict[str, int] = field(default_factory=dict)  # expected auto, queued (per scenario)
    bad_reason: list[str] = field(default_factory=list)  # expected in the queue for another reason
    auto_unexpected: int = 0  # expected in the queue, matched automatically to the right file
    gated: int = 0  # matched automatically to the right file, then held for ops by the gating
    by_scenario: dict[str, list[int]] = field(default_factory=dict)  # [count, auto]

    def add(
        self, c: Credit, line: str, account: str | None, reason: str | None, gated: bool = False
    ) -> None:
        """`account`: the file a rule matched (None: left to ops, with `reason`); `gated`: the
        automatic match was then held for ops (file not confirmed, closed, nothing due…)."""
        self.total += 1
        row = self.by_scenario.setdefault(c.scenario, [0, 0])
        row[0] += 1
        if account is not None:
            self.auto += 1
            row[1] += 1
            if account != c.truth:
                self.wrong.append(f"{line} ({c.scenario}): matched {account}, truth {c.truth}")
            elif c.expect != "auto":
                self.auto_unexpected += 1
            self.gated += int(gated)
            return
        self.queued += 1
        if c.expect == "auto":
            self.missed[c.scenario] = self.missed.get(c.scenario, 0) + 1
        elif reason != c.expect:
            self.bad_reason.append(f"{line} ({c.scenario}): reason {reason}, expected {c.expect}")

    @property
    def rate(self) -> float:
        return self.auto / self.total if self.total else 0.0

    @property
    def ready_rate(self) -> float:
        """Matched automatically and ready for allocation (not held by the gating)."""
        return (self.auto - self.gated) / self.total if self.total else 0.0

    def report(self) -> dict[str, Any]:
        return {
            "credits": self.total,
            "auto": self.auto,
            "auto_rate": f"{self.rate:.4f}",
            "gated": self.gated,
            "ready_rate": f"{self.ready_rate:.4f}",
            "wrong": len(self.wrong),
            "queued": self.queued,
            "missed_by_scenario": dict(sorted(self.missed.items())),
            "queued_with_another_reason": len(self.bad_reason),
            "auto_where_queue_expected": self.auto_unexpected,
            "by_scenario": {
                k: {"credits": v[0], "auto": v[1]} for k, v in sorted(self.by_scenario.items())
            },
        }
