"""Synthetic EU NPL template tape (Regulation (EU) 2023/2083): French households and SMEs
with unsecured consumer and professional loans, co-borrowers, and 36 months of collections.

Values use the Annex III formats (DD/MM/YYYY dates, numbers with 2 decimals, Yes/No, full choice
labels) so a tape validates against the template JSON Schema. Deterministic for a given seed.
"""

from __future__ import annotations

import csv
import datetime as dt
import random
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

from faker import Faker

from collectoo_worker.eba.catalogue import Field, columns, fields
from collectoo_worker.synth.ids import siren

Row = dict[str, str]
Tape = dict[str, list[Row]]

HISTORY_MONTHS = 36
NACE = ["47.11", "56.10", "43.21", "45.20", "49.41", "62.01", "68.20", "86.21", "96.02", "10.71"]


def _d(value: dt.date) -> str:
    return value.strftime("%d/%m/%Y")


def _n(value: Decimal) -> str:
    return str(value.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def _blank(template_id: str) -> Row:
    return dict.fromkeys(columns(template_id), "")


def _applies(f: Field, corporate: bool) -> bool:
    if f.borrower_type == "Corporate":
        return corporate
    if f.borrower_type == "Private Individual":
        return not corporate
    return True


def _filler(f: Field, rng: random.Random, cutoff: dt.date) -> str:
    """Plausible value for fields without a dedicated rule."""
    if f.allowed_values:
        return f.allowed_values[0]
    match f.data_type:
        case "Date":
            return _d(cutoff - dt.timedelta(days=rng.randint(30, 900)))
        case "Number":
            return _n(Decimal(rng.randint(0, 50_000)))
        case "Percentage":
            return _n(Decimal(rng.randint(0, 100)) / 100)
        case "Boolean":
            return "No"
        case _:
            return ""


def _counterparty(fake: Faker, rng: random.Random, n: int, corporate: bool, cutoff: dt.date) -> Row:
    row = _blank("T1")
    for f in fields():
        if f.template_id == "T1" and _applies(f, corporate) and f.mandatory:
            row[f.column] = _filler(f, rng, cutoff)
    ref = f"CPTY-{n:06d}"
    if corporate:
        name = fake.company()
        row.update(
            {
                "f1_00_counterparty_group_identifier": f"GRP-{n:06d}",
                "f1_01_name_of_counterparty_group": name,
                "f1_04_economic_activity": rng.choice(NACE),
                "f1_06_legal_type_of_counterparty": "Non-financial corporations-SMEs",
                "f1_10_national_identifier": siren(rng),
                "f1_12_source_of_national_identifier": "INSEE (répertoire SIRENE)",
                "f1_14_address_of_counterparty": fake.street_address(),
                "f1_15_city_of_counterparty": fake.city(),
                "f1_21_date_of_latest_annual_financial_statements": _d(
                    dt.date(cutoff.year - 1, 12, 31)
                ),
                "f1_22_currency_of_financial_statements": "EUR",
                "f1_29_annual_turnover": _n(Decimal(rng.randint(80_000, 4_000_000))),
            }
        )
    else:
        name = f"{fake.last_name().upper()} {fake.first_name()}"
        birth = fake.date_of_birth(minimum_age=21, maximum_age=85)
        row.update(
            {
                "f1_00_counterparty_group_identifier": f"GRP-{n:06d}",
                "f1_01_name_of_counterparty_group": f"Foyer {name.split()[0]}",
                "f1_06_legal_type_of_counterparty": "Households",
                "f1_07_date_of_birth": _d(birth),
            }
        )
    row.update(
        {
            "f1_02_counterparty_identifier": ref,
            "f1_03_name_of_counterparty": name,
            "f1_05_role_of_the_counterparty": "Borrower",
            "f1_08_residency_of_counterparty": "Yes",
            "f1_09_counterparty_deceased": "Yes" if rng.random() < 0.01 else "No",
            "f1_16_postal_code_of_counterparty": fake.postcode(),
            "f1_17_country_of_counterparty": "FR",
            "f1_18_availability_of_e_mail_address": "Yes" if rng.random() < 0.6 else "No",
            "f1_19_availability_of_telephone_number": "Yes" if rng.random() < 0.75 else "No",
            "f1_20_date_of_last_contact": _d(cutoff - dt.timedelta(days=rng.randint(20, 700))),
            "f1_32_status_of_legal_proceedings": "No legal action taken",
        }
    )
    return row


def _loan(rng: random.Random, n: int, corporate: bool, cutoff: dt.date) -> Row:
    row = _blank("T3")
    for f in fields():
        if f.template_id == "T3" and f.mandatory:
            row[f.column] = _filler(f, rng, cutoff)
    inception = cutoff - dt.timedelta(days=rng.randint(700, 3000))
    years = rng.choice([3, 4, 5, 7]) if corporate else rng.choice([2, 3, 4, 5, 6])
    maturity = inception + dt.timedelta(days=365 * years)
    default = inception + dt.timedelta(
        days=rng.randint(200, max(201, (cutoff - inception).days - 60))
    )
    principal = Decimal(rng.randint(15_000, 250_000) if corporate else rng.randint(1_500, 35_000))
    principal = principal * Decimal(rng.randint(30, 90)) / 100
    rate = Decimal(rng.randint(350, 900) if corporate else rng.randint(290, 1600)) / 10_000
    accrued = principal * rate * Decimal((cutoff - default).days) / 365
    other = Decimal(rng.randint(0, 600))
    last_payment = default - dt.timedelta(days=rng.randint(10, 120))
    row.update(
        {
            "f3_00_cut_off_date": _d(cutoff),
            "f3_01_loan_identifier": f"LOAN-{n:06d}",
            "f3_02_inception_date": _d(inception),
            "f3_03_governing_law_of_loan_agreement": "FR",
            "f3_04_joint_counterparties": "no joint counterparties",
            "f3_05_asset_class": "Corporate" if corporate else "Consumer",
            "f3_06_type_of_instrument": "Other loans",
            "f3_07_legal_final_maturity_date": _d(maturity),
            "f3_08_currency": "EUR",
            "f3_09_principal_amount": _n(principal),
            "f3_10_accrued_interest": _n(accrued),
            "f3_11_other_balances": _n(other),
            "f3_12_legal_balance": _n(principal + accrued.quantize(Decimal("0.01")) + other),
            "f3_13_days_in_past_due": _n(Decimal((cutoff - default).days)),
            "f3_14_interest_rate": _n(rate),
            "f3_15_interest_rate_type": "Fixed",
            "f3_19_interest_rate_reset_frequency": "Not resettable",
            "f3_20_payment_frequency": "Monthly",
            "f3_21_last_payment_date": _d(last_payment),
            "f3_22_last_payment_amount": _n(Decimal(rng.randint(50, 900))),
            "f3_23_date_of_the_default_status_of_the_instrument": _d(default),
            "f3_24_loan_legal_status": "no legal or 'out of court' action taken",
            "f3_29_statute_of_limitations_date": _d(
                default + dt.timedelta(days=(5 if corporate else 2) * 365)
            ),
            "f3_30_syndicated_loan": "No",
            "f3_32_securitised": "No",
            "f3_33_lease_agreement": "No",
            "f3_38_forbearance_measure": "No",
        }
    )
    return row


def _history(rng: random.Random, loan_ref: str) -> list[Row]:
    rows = []
    paying = rng.random() < 0.35
    for month in range(1, HISTORY_MONTHS + 1):
        amount = Decimal(rng.randint(20, 300)) if paying and rng.random() < 0.4 else Decimal(0)
        rows.append(
            {
                "f5_00_loan_identifier": loan_ref,
                "f5_01_type_of_collection": "Internal",
                "f5_02_name_of_external_collection_agent": "",
                "month_offset": str(month),
                "f5_03_history_of_total_repayments": _n(amount),
                "f5_04_history_of_repayments_from_collateral_sales": "0.00",
            }
        )
    return rows


def generate_eba(loans: int, seed: int, cutoff: dt.date = dt.date(2026, 9, 30)) -> Tape:
    """A tape with `loans` loans: ~30 % SME loans, ~10 % of household loans with a co-borrower."""
    rng = random.Random(seed)
    fake = Faker("fr_FR")
    fake.seed_instance(seed)
    tape: Tape = {
        "t1_counterparty": [],
        "t2_1_borrower_loan": [],
        "t3_loan": [],
        "t5_collection": [],
    }
    cpty_n = 0
    for n in range(1, loans + 1):
        corporate = rng.random() < 0.3
        cpty_n += 1
        borrower = _counterparty(fake, rng, cpty_n, corporate, cutoff)
        loan = _loan(rng, n, corporate, cutoff)
        tape["t1_counterparty"].append(borrower)
        links = [borrower["f1_02_counterparty_identifier"]]
        if not corporate and rng.random() < 0.1:
            cpty_n += 1
            co = _counterparty(fake, rng, cpty_n, False, cutoff)
            tape["t1_counterparty"].append(co)
            links.append(co["f1_02_counterparty_identifier"])
            loan["f3_04_joint_counterparties"] = "two counterparties"
        tape["t3_loan"].append(loan)
        for ref in links:
            tape["t2_1_borrower_loan"].append(
                {
                    "f2_00_counterparty_identifier": ref,
                    "f2_01_loan_identifier": loan["f3_01_loan_identifier"],
                }
            )
        tape["t5_collection"].extend(_history(rng, loan["f3_01_loan_identifier"]))
    return tape


def write_tape(tape: Tape, out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for table, rows in tape.items():
        path = out_dir / f"{table}.csv"
        with path.open("w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else [])
            writer.writeheader()
            writer.writerows(rows)
        paths.append(path)
    return paths
