import type { ErrorCode } from "@/lib/boarding/forms";
import type { Tone } from "@/lib/payments/statements";

/**
 * M2b-4: allocation on the back-office (payment page, file page). Pure helpers, unit-tested. The worker's
 * waterfall decides the allocation (legal order, no model); these pages show it from the ledger and let
 * admins and ops managers act on it. Amounts arrive as text (integer minor units): they never pass through
 * a JS number.
 */

/** Where a payment stands (payment.status), in French. */
export const PAYMENT_STATUS: Record<string, { label: string; tone: Tone }> = {
  unmatched: { label: "Sans dossier", tone: "action" },
  matched: { label: "Rapproché, non imputé", tone: "busy" },
  allocated: { label: "Imputé", tone: "ok" },
  partially_allocated: { label: "Imputé en partie", tone: "action" },
  refund_pending: { label: "Remboursement demandé", tone: "busy" },
  refunded: { label: "Remboursé", tone: "neutral" },
  returned: { label: "Retourné par la banque", tone: "neutral" },
};

export function paymentStatus(status: string): { label: string; tone: Tone } {
  return PAYMENT_STATUS[status] ?? { label: status, tone: "neutral" };
}

/** Balance components (public.ledger_component), as the receipt and the file page name them. */
export const COMPONENT_LABEL: Record<string, string> = {
  principal: "Principal",
  accrued_interest: "Intérêts échus",
  other_balances: "Autres sommes déclarées par le cédant",
  balancing_line: "Écart au solde légal déclaré",
};

export function componentLabel(code: string): string {
  return COMPONENT_LABEL[code] ?? code;
}

/** Ledger entries a payment can have, in French. */
export const ENTRY_LABEL: Record<string, string> = {
  allocation: "Imputation",
  reversal: "Imputation annulée",
  forward: "Reversé au client sans imputation",
  cash_out: "Restitution ou retour",
};

/** What the client was told (client_notification.kind, R124-5). */
export const NOTIFICATION_LABEL: Record<string, string> = {
  payment_allocated: "Informé de l'imputation",
  payment_allocation_reversed: "Informé de l'annulation de l'imputation",
  payment_forwarded: "Informé du reversement",
  payment_held: "Informé que le paiement est retenu",
};

export type Line = {
  claim_item_id: string;
  item_ref: string;
  item_kind: string;
  due_date: string | null;
  component: string;
  amount_minor: string;
};

export type Entry = {
  entry_id: string;
  entry_type: string;
  effective_date: string;
  posted_at: string;
  reason: string | null;
  account_id: string | null;
  external_ref: string | null;
  reverses_entry_id: string | null;
  reversed_by: string | null;
  amount_minor: string | null;
  lines: Line[];
};

export type PaymentDetail = {
  payment: {
    id: string;
    amount_minor: string;
    currency: string;
    booking_date: string;
    value_date: string | null;
    payer_name: string | null;
    payer_iban_end: string | null;
    remittance_text: string | null;
    creditor_reference: string | null;
    end_to_end_id: string | null;
    status: string;
    review_reason: string | null;
    account_id: string | null;
    match_method: string | null;
    matched_at: string | null;
    designation: { item_ids?: string[] } | null;
    instruction: { release?: string; account_id?: string } | null;
    channel: string;
    method: string;
  };
  position: { allocated_minor: string; unallocated_minor: string; returned_minor: string };
  file: {
    account_id: string;
    external_ref: string;
    status: string;
    client_organization_id: string;
    client_name: string;
    currency: string;
    legal_regime: string;
    debtor_name: string | null;
  } | null;
  matches: {
    action: string;
    account_id: string;
    external_ref: string;
    method: string;
    rule: string | null;
    trigger: string;
    reason: string | null;
    review_reason: string | null;
    decided_at: string;
    by_ops: boolean;
  }[];
  entries: Entry[];
  notifications: { kind: string; created_at: string; client_name: string; reason: string | null }[];
  documents: { id: string; kind: string; created_at: string }[];
  other_files: { account_id: string; external_ref: string }[];
};

/** Allocation entries still in force (not reversed), per file: what « Désimputer » acts on. */
export function liveAllocations(entries: Entry[]): Map<string, Entry[]> {
  const out = new Map<string, Entry[]>();
  for (const e of entries) {
    if (e.entry_type !== "allocation" || e.reversed_by || !e.account_id) continue;
    out.set(e.account_id, [...(out.get(e.account_id) ?? []), e]);
  }
  return out;
}

/** The allocation of a payment per item and component, summed over its live entries (what the receipt lists). */
export function allocationRows(entries: Entry[]): { key: string; file: string | null; line: Line; minor: bigint }[] {
  const rows = new Map<string, { key: string; file: string | null; line: Line; minor: bigint }>();
  for (const e of entries) {
    if (e.entry_type !== "allocation" || e.reversed_by) continue;
    for (const l of e.lines) {
      const key = `${l.claim_item_id}:${l.component}`;
      const row = rows.get(key);
      if (row) row.minor += BigInt(l.amount_minor);
      else rows.set(key, { key, file: e.external_ref, line: l, minor: BigInt(l.amount_minor) });
    }
  }
  return [...rows.values()];
}

/** Reasons ops may send back to allocation from (« Imputer »). */
const REALLOCATE_FROM = new Set(["allocation_reversed", "nothing_due", "credit_note_to_apply", "before_servicing_start"]);
const CLOSED = new Set(["closed_paid", "closed_settled", "closed_uncollectable", "closed_recalled"]);

/** Which actions the payment page offers (the SQL commands check again; this only hides what cannot work). */
export function paymentActions(d: Pick<PaymentDetail, "payment" | "position" | "file" | "entries" | "other_files">): {
  reverse: boolean;
  allocate: boolean;
  releaseHold: boolean;
  forward: boolean;
  otherFile: boolean;
  unassign: boolean;
} {
  const p = d.payment;
  const allocated = BigInt(d.position.allocated_minor);
  const left = BigInt(d.position.unallocated_minor);
  const live = liveAllocations(d.entries);
  return {
    reverse: live.size > 0,
    allocate: p.status === "matched" && p.review_reason !== null && REALLOCATE_FROM.has(p.review_reason),
    releaseHold: p.status === "matched" && p.review_reason === "hold_blocks_allocation",
    forward:
      allocated === BigInt(0) &&
      left > BigInt(0) &&
      p.status === "matched" &&
      (p.review_reason === "before_servicing_start" || d.file?.status === "closed_recalled"),
    otherFile:
      left > BigInt(0) &&
      d.other_files.length > 0 &&
      ((p.status === "partially_allocated" && p.review_reason === "overpayment") ||
        (p.status === "matched" && p.review_reason === "nothing_due")),
    unassign: p.status === "matched" && allocated === BigInt(0) && p.account_id !== null,
  };
}

/** What « Imputer » does, by the reason the payment waits for (the sheet says it before anything is sent). */
export const REALLOCATE_TEXT: Record<string, string> = {
  allocation_reversed: "Le paiement sera imputé à nouveau sur ce dossier, dans l'ordre légal.",
  nothing_due: "Le paiement sera imputé sur ce dossier s'il présente à nouveau un solde ; sinon il reviendra ici.",
  credit_note_to_apply:
    "Le paiement sera imputé sans appliquer l'avoir du dossier (la compensation n'est pas invoquée).",
  before_servicing_start:
    "Le solde du cédant ne tient pas compte de ce paiement : il sera imputé à la date d'arrêté, dans l'ordre légal.",
};

/** A file's open status as words. */
export function fileIsOpen(status: string): boolean {
  return status !== "staged" && !CLOSED.has(status);
}

/** Errors of the allocation commands, as codes (order matters: most specific first). */
export function allocationErrorCode(message: string): ErrorCode {
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("reason is required")) return "reason_required";
  if (message.includes("allocation changed")) return "allocation_changed";
  if (message.includes("the payment changed") || message.includes("is not held")) return "payment_changed";
  if (message.includes("amount changed")) return "amount_changed";
  if (message.includes("proposal changed")) return "proposal_changed";
  if (message.includes("no credit note to apply")) return "proposal_changed";
  if (message.includes("authorisation is required")) return "authorisation_required";
  if (message.includes("written request is required")) return "request_required";
  if (message.includes("same debtor") || message.includes("open file of the same client")) return "not_same_debtor";
  if (message.includes("nothing was allocated from") || message.includes("only when the client recalled"))
    return "not_forwardable";
  if (message.includes("lock") || message.includes("canceling statement")) return "allocation_busy";
  if (message.includes("is allocated")) return "payment_allocated";
  return "unknown";
}

/** RF reference printed as on letters (groups of four). */
export function groupsOfFour(text: string | null): string {
  return (text ?? "").replace(/\s/g, "").replace(/(.{4})(?=.)/g, "$1 ");
}

export type Proposal = {
  credit_item_id: string;
  credit_ref: string;
  netting_date: string;
  proposal_key: string;
  amount_minor: string;
  targets: { item_id: string; item_ref: string; amount_minor: string }[];
};

export type AccountDetail = {
  account: {
    id: string;
    external_ref: string;
    status: string;
    currency: string;
    legal_regime: string;
    claim_type: string;
    client_name: string;
    portfolio_name: string;
    servicing_start: string | null;
  };
  can_act: boolean;
  parties: { name: string; role: string }[];
  rf: string | null;
  balances: {
    claim_item_id: string;
    item_ref: string;
    kind: string;
    due_date: string | null;
    component: string;
    balance_minor: string;
  }[];
  holds: { kind: string; started_at: string; legal_basis: string | null; reason: string }[];
  payments: {
    id: string;
    amount_minor: string;
    currency: string;
    booking_date: string;
    status: string;
    review_reason: string | null;
    payer_name: string | null;
  }[];
  proposal: Proposal | null;
};

export type ItemBalance = {
  id: string;
  ref: string;
  kind: string;
  due: string | null;
  components: { component: string; minor: bigint }[];
  total: bigint;
};

/** Balances per item (components in the order the page received them), and the file's total. */
export function itemBalances(rows: AccountDetail["balances"]): { items: ItemBalance[]; total: bigint } {
  const items = new Map<string, ItemBalance>();
  let total = BigInt(0);
  for (const r of rows) {
    const minor = BigInt(r.balance_minor);
    const item = items.get(r.claim_item_id) ?? {
      id: r.claim_item_id,
      ref: r.item_ref,
      kind: r.kind,
      due: r.due_date,
      components: [],
      total: BigInt(0),
    };
    item.components.push({ component: r.component, minor });
    item.total += minor;
    total += minor;
    items.set(r.claim_item_id, item);
  }
  return { items: [...items.values()], total };
}

/** « L'avoir AV-105 réglera F-101 pour 200,00 € (200,00 € au total), à la date du 30/09/2026, … » */
export function proposalSummary(p: Proposal, money: (minor: string) => string, date: (iso: string) => string): string {
  const targets = p.targets.map((t) => `${t.item_ref} pour ${money(t.amount_minor)}`).join(", ");
  return `L'avoir ${p.credit_ref} réglera ${targets} (${money(p.amount_minor)} au total), à la date du ${date(p.netting_date)}, où les deux étaient exigibles.`;
}

/** Holds (account_hold.kind) in French. */
export const HOLD_LABEL: Record<string, string> = {
  dispute: "Litige",
  surendettement: "Surendettement",
  collective_proceeding: "Procédure collective",
  recalled: "Rappel par le client",
  wrong_party: "Mauvais débiteur",
};
