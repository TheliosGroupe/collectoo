import { frenchDate } from "@/lib/payments/bank-accounts";
import type { Tone } from "@/lib/payments/statements";

/**
 * M2b-5: receipts (R124-6) and the client payment feed (R124-5). Pure helpers, unit-tested. The worker builds each
 * receipt from the ledger and renders its PDF; these pages list the versions and the feed. Amounts arrive as text
 * (integer minor units): they never pass through a JS number.
 */

export type ReceiptVersion = {
  id: string;
  number: string;
  version: number;
  kind: string;
  known_at: string;
  issued_at: string;
  pdf_sha256: string;
  account_id: string;
};

/** What a receipt version is (receipt.kind). */
export const RECEIPT_KIND: Record<string, { label: string; tone: Tone }> = {
  original: { label: "Originale", tone: "ok" },
  update: { label: "Mise à jour", tone: "ok" },
  void: { label: "Annulée", tone: "neutral" },
};

/** The versions of a payment's receipt, latest first: the latest is in force, the others replaced (kept). */
export function receiptVersions(rows: ReceiptVersion[]): (ReceiptVersion & { current: boolean; label: string })[] {
  const sorted = [...rows].sort((a, b) => b.version - a.version);
  return sorted.map((r, i) => ({
    ...r,
    current: i === 0,
    label:
      r.version === 1
        ? "Version 1"
        : `Version ${r.version} – ${r.kind === "void" ? "annule" : "remplace"} la version ${r.version - 1}`,
  }));
}

/** A SHA-256 short enough for a phone, long enough to compare by eye. */
export function shortHash(sha: string): string {
  return sha.length > 16 ? `${sha.slice(0, 8)}…${sha.slice(-8)}` : sha;
}

export function receiptFileName(r: Pick<ReceiptVersion, "number" | "version">): string {
  return `${r.number}-v${r.version}.pdf`;
}

/**
 * Whether the page should wait for a receipt version: only while a receipts job naming the payment is queued, running
 * or waiting for a retry (`receipt_job_pending`). The job's outcome decides, not the times of the latest entry and
 * version: a job that found the receipt unchanged (an allocation reversed and made again with the same lines) issues
 * nothing and ends the wait like one that issued a version (review #18). A payment waiting for its allocation gets its
 * receipt after it (the allocation queues the job). Not told (`null`): no wait.
 */
export function receiptPending(o: { waitingForAllocation: boolean; jobQueued: boolean | null }): boolean {
  return !o.waitingForAllocation && o.jobQueued === true;
}

/** A row of `client_payment_feed`. */
export type FeedRow = {
  notification_id: string;
  cursor: string;
  created_at: string;
  kind: string;
  reason: string | null;
  account_id: string | null;
  file_reference: string | null;
  debtor_name: string | null;
  amount_minor: string;
  currency: string;
  booking_date: string;
  effective_date: string | null;
  lines: { item_ref: string; item_kind: string; due_date: string | null; component: string; amount_minor: string }[];
  receipt_id: string | null;
  receipt_number: string | null;
  receipt_version: number | null;
  receipt_kind: string | null;
  delivered_at: string | null;
  first_view: boolean;
};

/** What the client is told (client_notification.kind), in French. */
export const FEED_KIND: Record<string, { label: string; tone: Tone; amount: string }> = {
  payment_allocated: { label: "Paiement imputé", tone: "ok", amount: "imputés" },
  payment_allocation_reversed: { label: "Imputation annulée", tone: "action", amount: "désimputés" },
  payment_forwarded: { label: "Paiement reversé sans imputation", tone: "ok", amount: "reversés sans imputation" },
  payment_held: { label: "Paiement mis en attente", tone: "action", amount: "reçus, non imputés" },
  payment_forward_reversed: { label: "Reversement annulé", tone: "action", amount: "repris" },
  payment_returned: { label: "Paiement retourné par la banque", tone: "action", amount: "repris par la banque" },
};

export function feedKind(kind: string): { label: string; tone: Tone; amount: string } {
  return FEED_KIND[kind] ?? { label: kind, tone: "neutral", amount: "" };
}

/** Why (client_notification.reason, a code: never ops' own words), in French. */
export const FEED_REASON: Record<string, string> = {
  hold_blocks_allocation:
    "Une procédure en cours sur ce dossier (surendettement ou procédure collective) empêche l'imputation : le paiement est conservé, il n'est ni imputé ni reversé.",
  ops_correction: "Imputation corrigée par nos services.",
  file_recalled: "Dossier rappelé : le paiement vous est reversé sans être imputé.",
  before_servicing_start:
    "Paiement antérieur à la date d'arrêté du portefeuille : il vous est reversé sans être imputé.",
  client_ratification: "Paiement reversé sur votre ratification.",
  // the return's own row (`payment_returned`), whatever the payment was before: allocated, forwarded, held or waiting
  bank_return: "La banque du payeur a repris ce montant (retour ou contestation).",
};

/**
 * Why, worded by what the row records (review M2b-6). A bank return writes one row per allocation it reversed, one per
 * forward it reversed, and one for the return itself: only an allocation's row says the invoices regain their balance,
 * a forward's says its remittance is cancelled (a forward imputes nothing), and the return's own row says no more than
 * that the bank took the amount back (a held or waiting payment had nothing imputed or remitted). The date is the
 * reversal's effective date.
 */
export function feedReason(row: Pick<FeedRow, "kind" | "reason" | "effective_date">): string | null {
  if (!row.reason) return null;
  if (row.reason === "bank_return") {
    const when = row.effective_date ? `au ${frenchDate(row.effective_date)}` : "à la date du retour";
    if (row.kind === "payment_allocation_reversed")
      return `La banque du payeur a repris tout ou partie de ce paiement (retour ou contestation) : son imputation est annulée ${when} et les factures retrouvent leur solde.`;
    if (row.kind === "payment_forward_reversed")
      return `La banque du payeur a repris tout ou partie de ce paiement (retour ou contestation) : son reversement est annulé ${when}.`;
  }
  return FEED_REASON[row.reason] ?? null;
}

/** The link to a receipt version and its words (« Quittance Q-2026-000001 · version 2 (annulée) »). */
export function feedReceiptLabel(row: Pick<FeedRow, "receipt_number" | "receipt_version" | "receipt_kind">): string | null {
  if (!row.receipt_number || row.receipt_version === null) return null;
  const base = `Quittance ${row.receipt_number} · version ${row.receipt_version}`;
  return row.receipt_kind === "void" ? `${base} (annulée)` : base;
}
