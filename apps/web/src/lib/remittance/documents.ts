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
    if (ref.transfer === false && ref.execution_date) {
      return `compensée le ${frenchDay(ref.execution_date)} avec vos encaissements (relevé ${ref.run_number}, aucun virement)`;
    }
    const remainder = ref.remainder_minor && /^\d+$/.test(ref.remainder_minor) && BigInt(ref.remainder_minor) > BigInt(0);
    if (remainder && ref.amount_minor && /^\d+$/.test(ref.amount_minor) && latest) {
      return `à régler par compensation sur le reversement ${ref.run_number} : ${money(ref.amount_minor, "EUR")} ; le solde de ${money(ref.remainder_minor as string, "EUR")} sur le prochain reversement, au plus tard le ${frenchDay(latest)}`;
    }
    return `à régler par compensation sur le reversement ${ref.run_number}`;
  }
  if (inv.due_date) {
    return `à régler par compensation sur un reversement, au plus tard le ${frenchDay(inv.due_date)} pour ce que le reversement ne compense pas`;
  }
  return "à régler par compensation sur un reversement";
}

/** The status of a run in the client space: « ordonné » until the bank's debit is booked. */
export function runStatusText(status: string, net: string | null): string {
  if (status === "booked") return net === "0" ? "Réglé par compensation, sans virement" : "Virement débité de notre compte";
  if (status === "cancelled") return "Annulé avant son exécution";
  return "Virement ordonné";
}

/**
 * A statement's line in the client space, from its run as it stands (review M2c-5 figures#1 = tests-ui#1, K7): the
 * statement's payload is frozen when it is drawn, so its status stays « approved » after a cancellation or the debit;
 * the page reads `remittance_run.status` and `net_minor` live. A cancelled run shows no amount to transfer.
 */
export function statementRunView(run: { status: string; net_minor: string | number | null } | null): {
  label: string;
  tone: "neutral" | "ok" | "error";
  net: string | null;
} {
  if (!run) return { label: "Statut indisponible", tone: "neutral", net: null };
  const net = run.net_minor === null ? null : String(run.net_minor);
  const label = runStatusText(run.status, net);
  if (run.status === "cancelled") return { label, tone: "error", net: null };
  return { label, tone: run.status === "booked" ? "ok" : "neutral", net };
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
};

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
