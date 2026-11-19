/**
 * M2c-5 (design §10, §14, §17): words of the client space « Reversements » and « Factures », of the run's documents in
 * the back office, and the CSV writer of the accountant's export. Amounts stay text in minor units (never JS numbers);
 * the database computes them.
 */
import { money } from "@/lib/payments/statements";

export type StatementRow = {
  run_id: string;
  number: string;
  issue_date: string;
  currency: string;
  line_count: number;
  file_count: number;
  pdf_document_id: string;
  pdf_sha256: string;
  csv_document_id: string;
  csv_sha256: string;
};

export type InvoiceRow = {
  id: string;
  kind: string;
  number: string;
  issue_date: string;
  ttc_minor: number | string;
  settlement: string;
  due_date: string | null;
  run_id: string | null;
  payload: { buyer?: { invoice_acceptance_ref?: string | null } } | null;
};

/**
 * How an invoice reaches the client (CGI 289 VI): in the client space once the buyer accepted electronic invoices
 * (recorded at issue in its payload); otherwise the PDF is not served and the client space says so — never that it
 * was posted, since no dispatch is recorded yet (review M2c-5 legal#7, K6; OQ-74).
 */
export function invoiceDelivery(
  inv: Pick<InvoiceRow, "payload">,
  pdf: { document_id: string } | null,
): { mode: "pdf"; documentId: string } | { mode: "not_online" } | { mode: "pending" } {
  const accepted = Boolean(inv.payload?.buyer?.invoice_acceptance_ref?.trim());
  if (!accepted) return { mode: "not_online" };
  return pdf ? { mode: "pdf", documentId: pdf.document_id } : { mode: "pending" };
}

/** K6: what the client reads for an invoice whose PDF is not served (no claim of a postal dispatch). */
export const NOT_ONLINE_TEXT =
  "PDF non disponible en ligne : vous n'aviez pas accepté la facture électronique à son émission. Demandez-la au cabinet.";

/** « Facture » / « Avoir ». */
export function invoiceKind(kind: string): string {
  return kind === "credit_note" ? "Avoir" : "Facture";
}

/**
 * A netted document's payment reference, frozen at issue in its payload (review M2c-5 legal#4, legal#5): what the run
 * sets off (`mode` 'run', `amount_minor`; `transfer` false when N = 0) and the remainder with its latest date, or all
 * of it on the next run by a date (`mode` 'next_run'). Amounts are text in minor units.
 */
export type PaymentReference = {
  mode?: string;
  run_number?: string | null;
  execution_date?: string | null;
  transfer?: boolean | null;
  amount_minor?: string | null;
  remainder_minor?: string | null;
  latest_date?: string | null;
};

/**
 * How a document is settled, in the client's words, as its PDF states it (invoice.py `_payment_line`) — never
 * « payée » or « réglée » before the bank's debit (M2c-6). A netted invoice the run's plan sets off only in part, or
 * not at all, states the latest date of what is left (its `due_date`, legal#4); an N = 0 run's set-off is made at
 * the approval, with no transfer (legal#5).
 */
export function settlementText(
  inv: Pick<InvoiceRow, "kind" | "settlement" | "due_date"> & { payment_reference?: PaymentReference | null },
): string {
  if (inv.kind === "credit_note") return "déduit des factures qu'il rectifie";
  if (inv.settlement === "due") return inv.due_date ? `à régler au plus tard le ${frenchDay(inv.due_date)}` : "à régler";
  const ref = inv.payment_reference ?? null;
  const latest = ref?.latest_date ?? inv.due_date;
  if (ref?.mode === "next_run" && latest) {
    return `à régler par compensation sur le prochain reversement, au plus tard le ${frenchDay(latest)}`;
  }
  if (ref?.mode === "run" && ref.run_number) {
    const digits = (v: string | null | undefined): v is string => typeof v === "string" && /^\d+$/.test(v);
    const amount = digits(ref.amount_minor) ? money(ref.amount_minor, "EUR") : null;
    // the remainder the plan leaves open, with its date (review M2c-5 legal#4): stated whether or not money moves
    const remainder =
      digits(ref.remainder_minor) && BigInt(ref.remainder_minor) > BigInt(0) && latest
        ? ` ; le solde de ${money(ref.remainder_minor, "EUR")} sur le prochain reversement, au plus tard le ${frenchDay(latest)}`
        : "";
    if (ref.transfer === false && ref.execution_date) {
      // N = 0: set off at approval, no transfer (round 2: the amount and the remainder, as the PDF prints them)
      return `compensée le ${frenchDay(ref.execution_date)} avec vos encaissements (relevé ${ref.run_number}, aucun virement)${amount ? ` : ${amount}` : ""}${remainder}`;
    }
    if (remainder && amount) {
      return `à régler par compensation sur le reversement ${ref.run_number} : ${amount}${remainder}`;
    }
    return `à régler par compensation sur le reversement ${ref.run_number}`;
  }
  if (inv.due_date) {
    return `à régler par compensation sur un reversement, au plus tard le ${frenchDay(inv.due_date)} pour ce que le reversement ne compense pas`;
  }
  return "à régler par compensation sur un reversement";
}

/**
 * The status of a run in the client space: « ordonné » until the bank's debit is booked. M2c-6b-2c (plan §7.4; critic
 * L6, critic2 ML-12): the debit's date (`remittance_run.booked_on`, the debit line's booking date the database records)
 * when the page has it; a cancelled run reads « Annulé avant la remise de son virement à la banque » (cancellation after
 * download is switched off: a cancelled run's transfer never reached the bank in a file) unless the bank executed one of
 * its chain's transfers all the same (`unplannedOn`, the summary's `unplanned_runs`), when saying so is the truth.
 */
export function runStatusText(
  status: string,
  net: string | null,
  bookedOn?: string | null,
  unplannedOn?: string | null,
  transferOutcome?: string | null,
): string {
  if (status === "booked") {
    if (net === "0") return "Réglé par compensation, sans virement";
    return bookedOn ? `Virement débité de notre compte le ${frenchDay(bookedOn)}` : "Virement débité de notre compte";
  }
  if (status === "cancelled")
    return unplannedOn
      ? `Annulé — la banque a néanmoins exécuté son virement le ${frenchDay(unplannedOn)} (voir le relevé suivant)`
      : // M2c-6b-3a-2 (T17): a run whose transfer the bank refused (a file closed « refusé par la banque », or its
        // transfer cancelled alone out of its live downloaded file) — the summary's per-run fact, never the switch
        transferOutcome === "not_executed"
        ? "Annulé : la banque n'a pas exécuté son virement (les relevés ne le montraient pas débité)"
        : // (review M2c-6b-3a-2 round 1, pages-texts-4) a debit that may be its transfer, not booked yet
          transferOutcome === "debit_pending"
          ? "Annulé — un débit de notre compte qui peut être son virement est en cours de vérification"
          : "Annulé avant la remise de son virement à la banque";
  return "Virement ordonné";
}

/**
 * A statement's line in the client space, from its run as it stands (review M2c-5 figures#1 = tests-ui#1, K7): the
 * statement's payload is frozen when it is drawn, so its status stays « approved » after a cancellation or the debit;
 * the page reads `remittance_run.status` and `net_minor` live. A cancelled run shows no amount to transfer.
 *
 * Review M2c-6b-1 (legal-texts#6, K4): a run whose payout the payee's bank sent back stays booked (design §9.7), so
 * « Virement débité de notre compte » in green would read as paid; `returned` (the summary's `returned_runs` entry:
 * the return credit's booking date) words it as come back unpaid, the amount kept. Review round 2 (L2,
 * new:client-returned-stale): the entry stays listed for good (a returned transfer never changes status), so it says
 * what became of the money — « … : son montant sera reversé par un prochain reversement » in the error tone until a run
 * holding the returned amount is booked, then « … : reversé à nouveau par le reversement <numéro> » (`repaid_by`), in
 * the neutral tone: the green stays the mark of a run whose own payout was debited.
 */
export function statementRunView(
  run: { status: string; net_minor: string | number | null; booked_on?: string | null } | null,
  returned?: { returned_on: string; repaid_by?: string | null } | null,
  unplannedOn?: string | null,
  transferOutcome?: string | null,
): {
  label: string;
  tone: "neutral" | "ok" | "error";
  net: string | null;
} {
  if (!run) return { label: "Statut indisponible", tone: "neutral", net: null };
  const net = run.net_minor === null ? null : String(run.net_minor);
  if (run.status === "booked" && returned?.returned_on) {
    const came = `Virement revenu impayé le ${frenchDay(returned.returned_on)}`;
    return returned.repaid_by
      ? { label: `${came} : reversé à nouveau par le reversement ${returned.repaid_by}`, tone: "neutral", net }
      : { label: `${came} : son montant sera reversé par un prochain reversement`, tone: "error", net };
  }
  const label = runStatusText(run.status, net, run.booked_on ?? null, unplannedOn ?? null, transferOutcome ?? null);
  if (run.status === "cancelled") return { label, tone: "error", net: null };
  return { label, tone: run.status === "booked" ? "ok" : "neutral", net };
}

/**
 * A run of the client whose payout came back (`client_remittance_summary.returned_runs`, review M2c-6b-1 K4), and the
 * number of the booked run whose live line holds the returned amount (`repaid_by`, review round 2 L2; null until then).
 */
export type ReturnedRun = { run_id: string; returned_on: string; amount_minor: string; repaid_by: string | null };

/**
 * The client's runs whose payout came back, by run id, from the summary's `returned_runs` (amounts text in minor
 * units, dates ISO, `repaid_by` a run's number or null — absent reads as null): an entry that is not well formed is
 * left out — the page then keeps the run's own words, never a guess.
 */
export function returnedRuns(summary: { returned_runs?: unknown } | null): Map<string, ReturnedRun> {
  const out = new Map<string, ReturnedRun>();
  const rows = summary?.returned_runs;
  if (!Array.isArray(rows)) return out;
  for (const r of rows as unknown[]) {
    if (!r || typeof r !== "object") continue;
    const { run_id, returned_on, amount_minor, repaid_by } = r as Record<string, unknown>;
    if (
      typeof run_id === "string" &&
      run_id !== "" &&
      typeof returned_on === "string" &&
      /^\d{4}-\d{2}-\d{2}$/.test(returned_on) &&
      typeof amount_minor === "string" &&
      /^\d+$/.test(amount_minor) &&
      (repaid_by === undefined || repaid_by === null || (typeof repaid_by === "string" && repaid_by.trim() !== ""))
    )
      out.set(run_id, { run_id, returned_on, amount_minor, repaid_by: typeof repaid_by === "string" ? repaid_by : null });
  }
  return out;
}

/**
 * A run in flight, as `client_remittance_summary` returns it in `owed[].in_flight_runs` (amounts text in minor units):
 * gross = net + commission + advances − refund. `advance_minor`, `refund_minor` and `requested_execution_date` are
 * named by the database (integration of the M2c-5 review); without them the difference gross − net − commission is
 * worded as a whole.
 */
export type InFlightRun = {
  number: string;
  status?: string;
  gross_minor: string;
  net_minor: string;
  commission_minor: string;
  advance_minor?: string | null;
  refund_minor?: string | null;
  requested_execution_date?: string | null;
};
export type OwedEntry = {
  currency: string;
  owed_minor: string;
  /** K2: Σ gross of the client's runs approved or sent and not booked, in this currency. */
  in_flight_gross_minor?: string | null;
  in_flight_runs?: InFlightRun[] | null;
};
export type RemittanceSummary = {
  owed: OwedEntry[];
  in_flight: { number: string; status: string; currency: string; net_minor: string; requested_execution_date: string | null }[];
  next_run_day?: string | null;
  /** review M2c-6b-1 (K4): the client's runs whose payout came back, and (round 2, L2) the run that paid each again
   * (read through returnedRuns) */
  returned_runs?: unknown;
  /** M2c-6b-2c (ML-12): the cancelled runs the bank executed all the same (read through unplannedRuns) */
  unplanned_runs?: unknown;
  /** M2c-6b-3a-2 (T17): what became of each cancelled run's transfer (read through cancelledRuns) */
  cancelled_runs?: unknown;
};

/**
 * M2c-6b-3a-2 (T17): the summary's `cancelled_runs` — each cancelled run's `transfer_outcome` by run id
 * (`not_executed`: the bank refused its transfer; `never_handed_out`: it never reached the bank; review round 1,
 * pages-texts-4: `debit_pending`, a debit that may be its transfer waits on a statement). An entry that is not
 * well formed is left out (the run then keeps « Annulé avant la remise de son virement à la banque », the summary
 * naming no other outcome).
 */
export function cancelledRuns(summary: { cancelled_runs?: unknown } | null): Map<string, string> {
  const out = new Map<string, string>();
  const rows = summary?.cancelled_runs;
  if (!Array.isArray(rows)) return out;
  for (const r of rows as unknown[]) {
    if (!r || typeof r !== "object") continue;
    const { run_id, transfer_outcome } = r as Record<string, unknown>;
    if (
      typeof run_id === "string" &&
      run_id !== "" &&
      (transfer_outcome === "not_executed" ||
        transfer_outcome === "never_handed_out" ||
        transfer_outcome === "debit_pending")
    )
      out.set(run_id, transfer_outcome);
  }
  return out;
}

/**
 * M2c-6b-2c (critic L6, critic2 ML-12): the client's cancelled runs whose payout the bank executed all the same, by
 * run id, with the date of the first such debit (the summary's `unplanned_runs`, keyed on every transfer of the run's
 * chain). An entry that is not well formed is left out — the run then keeps its own words.
 */
export function unplannedRuns(summary: { unplanned_runs?: unknown } | null): Map<string, string> {
  const out = new Map<string, string>();
  const rows = summary?.unplanned_runs;
  if (!Array.isArray(rows)) return out;
  for (const r of rows as unknown[]) {
    if (!r || typeof r !== "object") continue;
    const { run_id, executed_on } = r as Record<string, unknown>;
    if (typeof run_id === "string" && run_id !== "" && typeof executed_on === "string" &&
        /^\d{4}-\d{2}-\d{2}$/.test(executed_on))
      out.set(run_id, executed_on);
  }
  return out;
}

const isMinor = (v: unknown): v is string => typeof v === "string" && /^-?\d+$/.test(v);

/**
 * One in-flight run in words: what is transferred (a credit note refunded in it) and what is set off at the debit
 * (commission, the servicer's advances). `null` when the amounts the database names do not add up — never a guess.
 */
function inFlightDetail(r: InFlightRun, currency: string): string | null {
  const zero = BigInt(0);
  const gross = BigInt(r.gross_minor);
  const net = BigInt(r.net_minor);
  const commission = BigInt(r.commission_minor);
  let advances: bigint;
  let refund: bigint;
  let advancesLabel = "d'avances du cabinet";
  if (r.advance_minor != null || r.refund_minor != null) {
    if (!isMinor(r.advance_minor) || !isMinor(r.refund_minor)) return null;
    advances = BigInt(r.advance_minor);
    refund = BigInt(r.refund_minor);
    if (gross !== net + commission + advances - refund) return null;
  } else {
    // without the database's split, the difference as a whole (> 0: other sums owed to us; < 0: a refunded credit note)
    const other = gross - net - commission;
    advances = other > zero ? other : zero;
    refund = other < zero ? -other : zero;
    advancesLabel = "d'autres sommes dues au cabinet";
  }
  const transfer = `${money(r.net_minor, currency)} à virer${
    refund > zero ? ` dont ${money(refund.toString(), currency)} de remboursement d'avoir` : ""
  }`;
  const setOffs = [
    commission !== zero ? `${money(r.commission_minor, currency)} de commission` : null,
    advances !== zero ? `${money(advances.toString(), currency)} ${advancesLabel}` : null,
  ].filter((x): x is string => x !== null);
  return setOffs.length > 0 ? `${transfer} ; ${setOffs.join(" et ")} à compenser au débit du virement` : transfer;
}

/**
 * « À reverser à ce jour » reconciled with the payout in flight (review M2c-5 tests-ui#5, K2): the running 4670 balance
 * still holds the gross of a run approved and not debited (its gross leaves 4670 at the debit, M2c-6), so each
 * currency with such runs gets one sentence saying that part is the ordered payout — what it transfers and what it sets
 * off — and is not an extra amount. Nothing is « compensé » or « réglé » before the debit. `covered` names the runs
 * these sentences word (the page words any other run in flight on its own).
 */
export function inFlightNotes(summary: Pick<RemittanceSummary, "owed" | "in_flight"> | null): {
  sentences: string[];
  covered: Set<string>;
} {
  const sentences: string[] = [];
  const covered = new Set<string>();
  for (const o of summary?.owed ?? []) {
    const runs = o.in_flight_runs ?? [];
    // amounts are text in minor units; anything else is left to the page's own in-flight note (never a guess)
    const wellFormed = runs.every((r) => [r.gross_minor, r.net_minor, r.commission_minor].every(isMinor));
    if (!isMinor(o.in_flight_gross_minor) || !isMinor(o.owed_minor) || !wellFormed || runs.length === 0) continue;
    if (BigInt(o.in_flight_gross_minor) === BigInt(0)) continue;
    const details = runs.map((r) => inFlightDetail(r, o.currency));
    if (details.some((d) => d === null)) continue;
    const head = `À reverser à ce jour : ${money(o.owed_minor, o.currency)}, dont ${money(o.in_flight_gross_minor, o.currency)}`;
    if (runs.length === 1) {
      const r = runs[0];
      const date =
        r.requested_execution_date ?? summary?.in_flight.find((f) => f.number === r.number)?.requested_execution_date;
      sentences.push(
        `${head} compris dans le reversement ${r.number} ordonné${date ? `, exécution demandée le ${frenchDay(date)}` : ""} (${details[0]}).`,
      );
    } else {
      const each = runs.map((r, i) => `${r.number} (${money(r.gross_minor, o.currency)} : ${details[i]})`);
      sentences.push(`${head} compris dans les reversements ordonnés ${each.slice(0, -1).join(", ")} et ${each[each.length - 1]}.`);
    }
    for (const r of runs) covered.add(r.number);
  }
  return { sentences, covered };
}

/**
 * A page of a client list (review M2c-5 tests-ui#7): `?page=N` (from 0), rows `from` … `to` inclusive — one row more
 * than the page shows, so the page knows whether older ones follow (« Plus anciens »).
 */
export function listPage(raw: string | string[] | undefined, size: number): { page: number; from: number; to: number } {
  const value = Array.isArray(raw) ? raw[0] : raw;
  const page = value !== undefined && /^\d{1,5}$/.test(value) ? Number(value) : 0;
  return { page, from: page * size, to: page * size + size };
}

/** The rows a page shows, and whether more follow (the query asked one more, `listPage`). */
export function pageOf<T>(rows: readonly T[] | null, size: number): { rows: T[]; more: boolean } {
  const all = rows ?? [];
  return { rows: all.slice(0, size), more: all.length > size };
}

/**
 * Where a run's statement stands on its back-office page (review M2c-5 perf#6 = tests-ui#3): a statement is queued
 * when the approval is recorded, so only a run with `approved_at` waits for one — a cancelled run approved before
 * included; a draft discarded or cancelled before its approval never gets one, and the page neither polls nor says
 * « en préparation ».
 */
export function runStatementState(
  run: { status: string; approved_at: string | null },
  statement: object | null,
): "drawn" | "pending" | "draft" | "none" {
  if (statement) return "drawn";
  if (run.approved_at) return "pending";
  return run.status === "draft" ? "draft" : "none";
}

export function frenchDay(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split("-");
  return `${d}/${m}/${y}`;
}

/** A period for the accountant's export: two ISO dates, at most 366 days apart (the database checks it too). */
export function exportPeriod(from: string | null, to: string | null): { from: string; to: string } | null {
  const iso = /^\d{4}-\d{2}-\d{2}$/;
  if (!from || !to || !iso.test(from) || !iso.test(to)) return null;
  const days = (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000;
  if (!Number.isFinite(days) || days < 0 || days > 366) return null;
  return { from, to };
}

const NBSP = " ";

/** « 1 234,56 »: integer minor units as the CSV writes them (no-break space between thousands, decimal comma). */
export function csvAmount(minor: string | number | bigint, exponent = 2): string {
  const value = BigInt(minor);
  const negative = value < BigInt(0);
  const abs = negative ? -value : value;
  const base = BigInt(10) ** BigInt(exponent);
  const units = (abs / base).toString().replace(/\B(?=(\d{3})+(?!\d))/g, NBSP);
  const fraction = exponent > 0 ? `,${(abs % base).toString().padStart(exponent, "0")}` : "";
  return `${negative ? "-" : ""}${units}${fraction}`;
}

/** K3: the first characters a spreadsheet reads as the start of a formula (= + - @, TAB, CR). */
const FORMULA_START = /^[=+\-@\t\r]/;

/** A text cell made inert: an apostrophe before a leading = + - @ TAB or CR (review M2c-5 security#0, K3). */
export function neutraliseText(value: string): string {
  return FORMULA_START.test(value) ? `'${value}` : value;
}

/**
 * A CSV in French conventions: UTF-8 with a BOM, `;`, CRLF, fields quoted when needed (RFC 4180). `textColumns` names
 * the header's free-text columns one by one: their cells are neutralised (K3) before quoting; every other column
 * (dates, amounts, cents, counts, rates) is written as given, so a negative amount stays « -12,34 ».
 */
export function csvFile(
  header: readonly string[],
  rows: readonly (readonly (string | null | undefined)[])[],
  textColumns: ReadonlySet<string>,
): string {
  for (const name of textColumns) {
    if (!header.includes(name)) throw new Error(`csvFile: text column ${name} is not in the header`);
  }
  const text = header.map((name) => textColumns.has(name));
  const quote = (s: string) => (/[;"\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s);
  const lines = rows.map((r) => r.map((v, i) => quote(text[i] ? neutraliseText(v ?? "") : (v ?? ""))).join(";"));
  return `﻿${[header.map(quote).join(";"), ...lines].join("\r\n")}\r\n`;
}
