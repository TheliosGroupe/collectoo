"""Synthetic reconciliation world and bank credits with a ground truth (M2-08; founder decision
#19: synthetic files only until anonymised real exports arrive).

A `World` is a servicer's files as matching sees them: references (RF), invoice, lease and loan
numbers, parties, open balances, and the IBANs that already paid a file. `generate_credits` writes
bank credits that pay them, each with its truth: the file it pays (or none) and what matching must
do with it (`auto`, or the queue with the reason ops will see). The mix follows design §13:

- 44.3 % structured RF (`CdtrRefInf`), the payer being the debtor or a third party;
- 25 % RF in the free text: grouped by four, lower case, glued, split over two lines;
- 5 % the 12 digits of the reference alone;
- 15 % invoice or loan numbers, backed by the payer's name (titles, word order, case, a typo) or,
  for a third party, by the exact balance of the invoices cited; the debtors drawn are those
  whose name backs a number (two words, or a word no other file has: rule R3);
- 6 % no reference, from an IBAN that already paid that file and no other;
- 0.7 % harder ones that must still match: a statement where an IBAN that paid file A pays
  file B by its RF (the RF credit), a debtor citing a month only another lease has, from the IBAN
  that paid his own lease (R4), a name written with Œ/Æ printed OE/AE by the bank;
- 4 % deliberately unmatchable: name and amount only, an RF with one wrong digit or two digits
  swapped (from a stranger, or from the IBAN that paid the file), two RFs one of which is
  mistyped, no information at all, an invoice number two files share, an IBAN that paid two
  files (earlier, or in this very statement), a month only another lease has at the same rent,
  the next invoice number of a file whose name shares one common word with the payer's.

Every name, IBAN and reference is synthetic (Faker fr_FR; valid check digits; random digits).
"""

from __future__ import annotations

import hashlib
import random
import string
import unicodedata
from collections import Counter
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Any

from faker import Faker

from collectoo_worker.payments.matching import (
    RARE_NAME_FILES,
    AccountInfo,
    Directory,
    ItemInfo,
    PaymentIn,
    is_date_digits,
    is_lookup_token,
    name_words,
    ref_key,
    shared_words,
    similarity,
)
from collectoo_worker.payments.rf import rf_format, rf_make
from collectoo_worker.synth.camt053 import Entry, Tx
from collectoo_worker.synth.ids import iban_fr

MIX: tuple[tuple[str, float], ...] = (
    ("rf_structured", 0.443),
    ("rf_text", 0.25),
    ("rf_body", 0.05),
    ("item_ref", 0.15),
    ("repeat_iban", 0.06),
    ("joint_rf", 0.002),
    ("month_key_iban", 0.002),
    ("ligature", 0.003),
    ("name_amount", 0.008),
    ("rf_typo", 0.006),
    ("no_info", 0.006),
    ("shared_ref", 0.005),
    ("iban_two_files", 0.004),
    ("joint_noref", 0.002),
    ("linked_rf_typo", 0.003),
    ("two_rfs_typo", 0.002),
    ("month_key", 0.002),
    ("homonym_typo", 0.002),
)
EXPECT = {
    "rf_structured": "auto",
    "rf_text": "auto",
    "rf_body": "auto",
    "item_ref": "auto",
    "repeat_iban": "auto",
    "joint_rf": "auto",
    "month_key_iban": "auto",
    "ligature": "auto",
    "name_amount": "no_match",
    "rf_typo": "no_match",
    "no_info": "no_match",
    "shared_ref": "ambiguous",
    "iban_two_files": "ambiguous",
    "joint_noref": "ambiguous",
    "linked_rf_typo": "no_match",
    "two_rfs_typo": "no_match",
    "month_key": "no_match",
    "homonym_typo": "no_match",
}
OPEN = ("awaiting_first_letter", "in_collection", "arrangement", "legal")
LIGATURE_NAMES = ("Lætitia {last}", "Le Cœur de {last}", "Sœurs {last} et Fils", "Bœuf {last} SARL")
_LIGATURES = str.maketrans({"Œ": "OE", "œ": "oe", "Æ": "AE", "æ": "ae"})


def bank_ascii(name: str) -> str:
    """How a bank prints a name: ligatures written out, accents dropped (SEPA character set)."""
    plain = unicodedata.normalize("NFKD", name.translate(_LIGATURES))
    return "".join(c for c in plain if not unicodedata.combining(c))


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


_Made = tuple[str, str, tuple[str, ...], list[ItemInfo]]  # kind, file number, parties, items


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

    def month_pair(self, n: int, k: int) -> list[_Made]:
        """Two leases at the same rent; the second also owes a month no other file has (written
        as YYYY-MM, MM/YYYY, YYYY-MM-DD or DD/MM/YYYY): what a payer citing it must not match."""
        rent = self.rng.randint(45_000, 180_000)
        year, month = 1990 + k // 12, k % 12 + 1
        written = (
            f"{year}-{month:02d}",
            f"{month:02d}/{year}",
            f"{year}-{month:02d}-01",
            f"01/{month:02d}/{year}",
        )[k % 4]
        out: list[_Made] = []
        for j, extra in enumerate(((), (written,))):
            m = n + j
            name = f"{self.fake.last_name().upper()} {self.fake.first_name()}"
            months = [
                f"2026-{x:02d}" for x in self.rng.sample(range(5, 11), self.rng.randint(1, 3))
            ]
            refs = [*months, *extra]
            items = [self.item(m, i, ref, rent) for i, ref in enumerate(refs)]
            out.append(("rent", f"BAIL-{m:06d}", (name,), items))
        return out

    def homonym_pair(self, n: int) -> list[_Made]:
        """Two companies with consecutive invoice numbers whose names share one surname (« Guillot »
        and « Guillot et Fils » or « Guillot S.A.S. », 62 % and 100 % alike): a typo in the number
        must not match the other one by name."""
        last = self.fake.last_name()
        names = (
            self.rng.choice((last, f"{last} SA", f"{last} SARL")),
            self.rng.choice((f"{last} et Fils", f"{last} S.A.S.")),
        )
        out: list[_Made] = []
        for j, name in enumerate(names):
            ref = f"FA-2026-{len(self.martin_refs) + 1:05d}"
            self.martin_refs.append(ref)
            item = self.item(n + j, 0, ref, self.rng.randint(5_000, 900_000))
            out.append(("invoice", f"MART-{n + j:06d}", (name,), [item]))
        return out

    def ligature(self, n: int, k: int) -> tuple[str, str, tuple[str, ...], list[ItemInfo]]:
        """A party whose name has Œ or Æ (the bank prints OE, AE)."""
        name = LIGATURE_NAMES[k % len(LIGATURE_NAMES)].format(last=self.fake.last_name())
        ext = f"CC2025{n:06d}"
        return "loan", ext, (name,), [self.item(n, 0, ext, self.rng.randint(50_000, 2_500_000))]


def synthetic_world(accounts: int, seed: int = 1) -> World:
    """Files of three clients: B2B invoices (two invoicing styles), rent, consumer loans. A few
    invoice numbers are shared by two clients' files; a quarter of the debtors already paid from
    their IBAN (the IBAN memory); a few IBANs paid two files (a parent paying for two children).
    Then, for the hard cases: pairs of leases at the same rent where one owes a month no other
    file has, pairs of companies with consecutive invoice numbers and one shared surname, and
    parties whose names have ligatures."""
    rng = random.Random(seed)
    fake = Faker("fr_FR")
    fake.seed_instance(seed)
    books = _Books(rng, fake, seed)
    made: list[_Made] = []
    for n in range(accounts):
        roll = rng.random()
        make = books.invoices if roll < 0.4 else books.lease if roll < 0.65 else books.loan
        made.append(make(n))
    for k in range(min(max(2, accounts // 125), 432)):  # 432 distinct months, 1990 to 2025
        made += books.month_pair(len(made), k)
    for _ in range(max(2, accounts // 500)):
        made += books.homonym_pair(len(made))
    for k in range(max(4, accounts // 250)):
        made.append(books.ligature(len(made), k))
    out: list[WorldAccount] = []
    bodies: set[str] = set()
    for n, (kind, ext, names, drawn) in enumerate(made):
        closed = n < accounts and rng.random() < 0.02
        items = [ItemInfo(i.id, i.ref, 0) for i in drawn] if closed else drawn
        body = f"{rng.randrange(10**12):012d}"
        while body in bodies:
            body = f"{rng.randrange(10**12):012d}"
        bodies.add(body)
        status = "closed_paid" if closed else rng.choice(OPEN)
        out.append(
            WorldAccount(_id(seed, n), ext, kind, status, rf_make(body), names, tuple(items))
        )
    world = with_history(World(out), rng)
    for a, _, _ in month_pairs(world):  # the debtor who cites the other lease's month paid before
        world.iban_links.setdefault(debtor_iban(a.id), {a.id: 1})
    return world


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


def _owners(world: World) -> dict[str, set[str]]:
    """Files per reference key (file and invoice numbers)."""
    owners: dict[str, set[str]] = {}
    for a in world.accounts:
        for key in {ref_key(a.external_ref), *(i.key for i in a.items)}:
            owners.setdefault(key, set()).add(a.id)
    return owners


def _workable(a: WorldAccount) -> bool:
    return a.status in OPEN and a.balance_minor > 0 and a.rf is not None


def month_pairs(world: World) -> list[tuple[WorldAccount, WorldAccount, ItemInfo]]:
    """(A, Y, month): leases where Y owes a month (a date) no other file has, and A, another
    lease, owes an item of exactly that amount. A's debtor citing that month must not pay Y."""
    owners = _owners(world)
    rents: dict[int, list[WorldAccount]] = {}
    for a in world.accounts:
        if a.kind == "rent" and _workable(a):
            for amount in {i.balance_minor for i in a.items}:
                rents.setdefault(amount, []).append(a)
    out = []
    for y in world.accounts:
        if y.kind != "rent" or not _workable(y):
            continue
        for i in y.items:
            if is_date_digits(i.key) and owners[i.key] == {y.id} and i.balance_minor > 0:
                others = sorted(
                    (a for a in rents.get(i.balance_minor, ()) if a.id != y.id),
                    key=lambda a: a.external_ref,
                )
                if others:
                    out.append((others[0], y, i))
    out.sort(key=lambda x: x[1].external_ref)
    return out


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
    # Unique invoices of files whose debtor's name backs a number by itself (rule R3: two words,
    # or a word no other file has): what a debtor citing their own invoice is matched by.
    named_items: list[tuple[WorldAccount, ItemInfo]] = field(default_factory=list)
    months: list[tuple[WorldAccount, WorldAccount, ItemInfo]] = field(default_factory=list)
    # (A, A's invoice, X, X's invoice): consecutive numbers, names sharing one common word only.
    homonyms: list[tuple[WorldAccount, ItemInfo, WorldAccount, ItemInfo]] = field(
        default_factory=list
    )
    ligatures: list[tuple[WorldAccount, ItemInfo]] = field(default_factory=list)

    @classmethod
    def of(cls, world: World) -> _Pools:
        open_ = [a for a in world.accounts if _workable(a)]
        owners = _owners(world)
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
        words: Counter[str] = Counter()  # files per name word, as the name index counts them
        for a in world.accounts:
            words.update({w for n in a.names for w in name_words(n) if len(w) >= 3})

        def named(a: WorldAccount) -> bool:
            for n in a.names:
                ws = set(name_words(n))  # « Joubert Joubert SARL » is one word
                if len(ws) >= 2 or (len(ws) == 1 and words[min(ws)] <= RARE_NAME_FILES):
                    return True
            return False

        return cls(
            world,
            open_,
            single,
            two,
            unique,
            shared,
            set(world.iban_links),
            named_items=[(a, i) for a, i in unique if named(a)],
            months=month_pairs(world),
            homonyms=_homonyms(world, unique, owners),
            ligatures=[(a, i) for a, i in unique if any(set("ŒœÆæ") & set(n) for n in a.names)],
        )


def _homonyms(
    world: World, unique: Sequence[tuple[WorldAccount, ItemInfo]], owners: dict[str, set[str]]
) -> list[tuple[WorldAccount, ItemInfo, WorldAccount, ItemInfo]]:
    """Files A and X with consecutive FA-2026 numbers whose names share exactly one word, a word
    other files have too, close enough (60 %) for the old rule to take the name as backing."""
    items = {i.key: (a, i) for a, i in unique}
    out = []
    for a, i in unique:
        if not i.ref.startswith("FA-2026-"):
            continue
        number = int(i.ref[-5:])
        for step in (-1, 1):
            nxt = ref_key(f"FA-2026-{number + step:05d}")
            if nxt not in items or len(owners.get(nxt, ())) != 1:
                continue
            x, j = items[nxt]
            if x.id == a.id:
                continue
            payer, party = a.names[0], x.names[0]
            if len(shared_words(payer, party)) == 1 and similarity(payer, party) >= 0.6:
                out.append((a, i, x, j))
    out.sort(key=lambda t: (t[1].ref, t[3].ref))
    return out


class _Writer:
    def __init__(
        self, world: World, seed: int, earlier: Sequence[Credit] = (), joints: int = 0
    ) -> None:
        self.rng = random.Random(seed)
        self.fake = Faker("fr_FR")
        self.fake.seed_instance(seed)
        self.p = _Pools.of(world)
        self.taken: dict[str, int] = {}  # paid to each file (earlier statements included)
        for c in earlier:
            if c.truth is not None:
                self.taken[c.truth] = self.taken.get(c.truth, 0) + c.amount_minor
        self.joints = self._reserve(joints)
        self.used: Counter[str] = Counter()  # credits written per paired scenario
        self.single_of = {a.id: iban for a, iban in self.p.single_link}

    def _reserve(self, n: int) -> list[tuple[str, str, WorldAccount, WorldAccount]]:
        """(IBAN, payer, A, B): an IBAN that paid file A only, which this statement sees pay file B
        by its RF and send a credit without reference (a parent paying two children's files). No
        other scenario uses these IBANs, so what the RF teaches changes nothing else."""
        months = {f.id for pair in self.p.months for f in pair[:2]}  # they pay a whole rent
        pool = [(a, iban) for a, iban in self.p.single_link if a.id not in months]
        others = [b for b in self.p.open_ if b.id not in months]
        if n <= 0 or not pool or len(others) < 2:
            return []
        out = []
        for a, iban in self.rng.sample(pool, min(n, len(pool))):
            b = self.pick(others)
            while b.id == a.id:
                b = self.rng.choice(others)
            out.append((iban, self.fake.name(), a, b))
        reserved = {iban for iban, _, _, _ in out}
        self.p.single_link = [x for x in self.p.single_link if x[1] not in reserved]
        return out

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
        write: Callable[[], Credit | None] | None = {
            "item_ref": self._item_ref if self.p.unique_items else None,
            "repeat_iban": self._repeat_iban if self.p.single_link else None,
            "name_amount": self._name_amount,
            "rf_typo": self._rf_typo,
            "shared_ref": self._shared_ref if self.p.shared_items else None,
            "iban_two_files": self._iban_two_files if self.p.two_files else None,
            "no_info": self._no_info,
            "joint_rf": self._joint_rf,
            "joint_noref": self._joint_noref,
            "linked_rf_typo": self._linked_rf_typo if self.p.single_link else None,
            "two_rfs_typo": self._two_rfs_typo if len(self.p.open_) >= 2 else None,
            "month_key": self._month_key,
            "month_key_iban": self._month_key_iban,
            "homonym_typo": self._homonym_typo if self.p.homonyms else None,
            "ligature": self._ligature if self.p.ligatures else None,
        }.get(scenario)
        written = write() if write is not None else None
        if written is not None:
            return written
        return self._by_reference("rf_structured", self.pick(self.p.open_))

    # -- the hard cases (review of M2b-3) -------------------------------------------------------

    def _joint(self, scenario: str) -> tuple[str, str, WorldAccount, WorldAccount] | None:
        k = self.used[scenario]
        self.used[scenario] += 1
        return self.joints[k] if k < len(self.joints) else None

    def _joint_rf(self) -> Credit | None:
        """The IBAN that paid A pays B by its RF (matched; it teaches the memory B)."""
        if (pair := self._joint("joint_rf")) is None:
            return None
        iban, name, _, b = pair
        amount = self.amount(b, share=0.1)
        return Credit(amount, name, iban, (), b.rf, b.id, "auto", "joint_rf")

    def _joint_noref(self) -> Credit | None:
        """…and, in the same statement, a credit without reference: A or B, ops decide."""
        if (pair := self._joint("joint_noref")) is None:
            return None
        iban, name, _, b = pair
        amount = self.amount(b, share=0.05)
        return Credit(amount, name, iban, ("VIREMENT",), None, b.id, "ambiguous", "joint_noref")

    def _linked_rf_typo(self) -> Credit:
        """From the IBAN that paid file A only, a mistyped RF (A's own, or another file's): the
        payer named something; the IBAN memory must not decide for them."""
        a, iban = self.pick(self.p.single_link, lambda x: x[0])
        target = a if self.rng.random() < 0.5 else self.pick(self.p.open_)
        bad = _typo(target.rf or "", self.rng)
        label = self.rng.choice(("LOYER", "REGLT", "Ref"))
        structured = self.rng.random() < 0.5
        text = () if structured else (f"{label} {rf_format(bad)}",)
        ref = bad if structured else None
        name = self.as_payer(a.names[0])
        amount = self.amount(target, share=0.1)
        return Credit(amount, name, iban, text, ref, target.id, "no_match", "linked_rf_typo")

    def _two_rfs_typo(self) -> Credit:
        """A's RF and B's mistyped one: the payer pays two files, the valid RF does not take all."""
        a = self.pick(self.p.open_)
        b = self.pick(self.p.open_)
        while b.id == a.id:
            b = self.rng.choice(self.p.open_)
        good, bad = a.rf or "", _typo(b.rf or "", self.rng)
        styles: tuple[tuple[tuple[str, ...], str | None], ...] = (
            ((f"REGLT {rf_format(good)} ET {rf_format(bad)}",), None),
            ((f"ET {rf_format(bad)}",), good),
            ((f"REGLT {rf_format(good)}",), bad),
        )
        text, ref = self.rng.choice(styles)
        amount = self.amount(a, share=0.1) + self.amount(b, share=0.1)
        name, iban = self.stranger(), self.fresh_iban()
        return Credit(amount, name, iban, text, ref, a.id, "no_match", "two_rfs_typo")

    def _month(self, *, linked: bool) -> tuple[WorldAccount, ItemInfo] | None:
        pool = [m for m in self.p.months if not linked or m[0].id in self.single_of]
        if not pool:
            return None
        for _ in range(30):
            a, _, month = self.rng.choice(pool)
            if self.left(a) >= month.balance_minor:
                self.taken[a.id] = self.taken.get(a.id, 0) + month.balance_minor
                return a, month
        return None

    def _month_key(self) -> Credit | None:
        """A's debtor pays his rent citing a month only lease Y has, at the same rent, from a new
        IBAN: a month names no file, so ops decide."""
        if (found := self._month(linked=False)) is None:
            return None
        a, month = found
        text = (self.rng.choice(("LOYER", "Loyer", "loyer du")) + f" {month.ref}",)
        name = self.as_payer(a.names[0])
        iban = self.fresh_iban()
        return Credit(month.balance_minor, name, iban, text, None, a.id, "no_match", "month_key")

    def _month_key_iban(self) -> Credit | None:
        """The same, from the IBAN that paid A only: R4 matches A (the month is not a number)."""
        if (found := self._month(linked=True)) is None:
            return None
        a, month = found
        text = (self.rng.choice(("LOYER", "Loyer", "loyer du")) + f" {month.ref}",)
        name, iban = self.as_payer(a.names[0]), self.single_of[a.id]
        return Credit(month.balance_minor, name, iban, text, None, a.id, "auto", "month_key_iban")

    def _homonym_typo(self) -> Credit:
        """A's debtor cites the next invoice number, X's, whose name shares one common word with
        his (« GUILLOT » and « Guillot et Fils »): not a backing name, ops decide."""
        a, _, x, other = self.pick(self.p.homonyms, lambda t: t[0])
        text = (self.rng.choice(("REGLT FACT", "VIR FACTURE N")) + f" {other.ref}",)
        amount = self.amount(a)
        if amount in (other.balance_minor, x.balance_minor):  # never X's exact balance
            amount -= 1
            self.taken[a.id] -= 1
        name = self.as_payer(a.names[0], typo=False)
        return Credit(amount, name, self.fresh_iban(), text, None, a.id, "no_match", "homonym_typo")

    def _ligature(self) -> Credit:
        """A loan of « Lætitia Durand », paid by « LAETITIA DURAND » citing its number."""
        a, item = self.pick(self.p.ligatures, lambda x: x[0])
        text = (self.rng.choice(("ECHEANCE PRET", "Remboursement credit n°")) + f" {item.ref}",)
        name = bank_ascii(self.as_payer(a.names[0], typo=False))
        return Credit(self.amount(a), name, self.fresh_iban(), text, None, a.id, "auto", "ligature")

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

    def _invoice_text(self, a: WorldAccount, item: ItemInfo) -> tuple[str, ...]:
        rng = self.rng
        texts: tuple[tuple[str, ...], ...]
        if a.kind == "rent":
            texts = ((f"LOYER {item.ref} {a.external_ref}",), (f"Loyer bail {a.external_ref}",))
        elif a.kind == "loan":
            texts = ((f"ECHEANCE PRET {item.ref}",), (f"Remboursement credit n°{item.ref}",))
        else:
            texts = ((f"REGLT FACT {item.ref}",), (f"VIR FACTURE N {item.ref}",))
        return rng.choice(texts)

    def _item_ref(self) -> Credit:
        """An invoice or loan number: a third party pays it to the cent (one time in five, while
        nothing was paid on the file), else the debtor, whose name backs a number by itself."""
        if self.rng.random() < 0.2:
            for _ in range(30):
                a, item = self.rng.choice(self.p.unique_items)
                if self.taken.get(a.id, 0) == 0:
                    self.taken[a.id] = item.balance_minor
                    text = self._invoice_text(a, item)
                    payer, iban = self.stranger(), self.fresh_iban()
                    return Credit(
                        item.balance_minor, payer, iban, text, None, a.id, "auto", "item_ref"
                    )
        a, item = self.pick(self.p.named_items or self.p.unique_items, lambda x: x[0])
        text = self._invoice_text(a, item)
        name = self.as_payer(self.rng.choice(a.names))
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
    counts = mix_counts(n)
    # The paired credits go together (one RF, one bare credit from the same IBAN).
    pairs = min(counts["joint_rf"], counts["joint_noref"])
    counts["rf_structured"] += counts["joint_rf"] + counts["joint_noref"] - 2 * pairs
    counts["joint_rf"] = counts["joint_noref"] = pairs
    w = _Writer(world, seed, earlier, joints=pairs)
    scenarios = [name for name, k in counts.items() for _ in range(k)]
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
    # Expected in the queue, matched automatically to the right file all the same: founder #3
    # forbids it (a name and an amount, a mistyped reference…), so it fails like a wrong match.
    policy_violations: list[str] = field(default_factory=list)
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
                self.policy_violations.append(
                    f"{line} ({c.scenario}): matched {account} automatically, expected {c.expect}"
                )
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
            "policy_violations": len(self.policy_violations),
            "by_scenario": {
                k: {"credits": v[0], "auto": v[1]} for k, v in sorted(self.by_scenario.items())
            },
        }
