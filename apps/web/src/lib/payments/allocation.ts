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

/** A forward is not an allocation (the debt is untouched): a forwarded payment has its own label (M2b-4 review). */
export function paymentStatus(status: string, opts: { forwarded?: boolean } = {}): { label: string; tone: Tone } {
  if (status === "allocated" && opts.forwarded) return { label: "Reversé au client", tone: "ok" };
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
  cash_out: "Sortie du compte de fonds de tiers (remboursement ou retour)",
};

/** An entry's words: a reversal says what it undid (an allocation, a forward, a refund that came back). */
export function entryLabel(e: Pick<Entry, "entry_type" | "reverses_type">): string {
  if (e.entry_type === "reversal") {
    if (e.reverses_type === "forward") return "Reversement annulé";
    if (e.reverses_type === "cash_out") return "Remboursement revenu impayé";
    return "Imputation annulée";
  }
  return ENTRY_LABEL[e.entry_type] ?? e.entry_type;
}

/** What a notification for the client is about (client_notification.kind). */
export const NOTIFICATION_LABEL: Record<string, string> = {
  payment_allocated: "Imputation",
  payment_allocation_reversed: "Annulation de l'imputation",
  payment_forwarded: "Reversement sans imputation",
  payment_held: "Paiement retenu (procédure)",
  payment_forward_reversed: "Annulation du reversement (retour bancaire)",
  payment_returned: "Paiement retourné par la banque",
};

export type Notification = {
  kind: string;
  created_at: string;
  client_name: string;
  reason: string | null;
  delivered_at: string | null;
};

/**
 * A notification as the page lists it: recorded for the client, and delivered only once a member of the client read
 * it in the client space (M2b-5 feed; webhooks come later): the page never says the client was informed before it
 * was (M2b-4 review).
 */
export function notificationText(n: Notification, when: (iso: string) => string): string {
  return `${NOTIFICATION_LABEL[n.kind] ?? n.kind} · ${notificationState(n, when)}`;
}

/** Whether a notification was delivered, in the words above (« notification enregistrée … (envoi : à venir) »). */
export function notificationState(n: Notification, when: (iso: string) => string): string {
  return n.delivered_at
    ? `notification remise à ${n.client_name} dans son espace client le ${when(n.delivered_at)}`
    : `notification enregistrée pour ${n.client_name} le ${when(n.created_at)} (envoi : à venir)`;
}

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
  ops_note: string | null;
  account_id: string | null;
  external_ref: string | null;
  reverses_entry_id: string | null;
  reverses_type?: string | null;
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
    payer_iban_valid?: boolean;
    remittance_text: string | null;
    creditor_reference: string | null;
    end_to_end_id: string | null;
    status: string;
    review_reason: string | null;
    account_id: string | null;
    match_method: string | null;
    matched_at: string | null;
    designation: { item_ids?: string[] } | null;
    instruction: { releases?: string[]; account_id?: string } | null;
    channel: string;
    method: string;
  };
  // allocated_minor counts forwards (design §7); forwarded_minor tells them apart
  position: {
    allocated_minor: string;
    unallocated_minor: string;
    returned_minor: string;
    forwarded_minor: string;
    left_minor?: string; // amount - what went back out (returns, refunds): what a return may take
  };
  file: {
    account_id: string;
    external_ref: string;
    status: string;
    client_organization_id: string;
    client_name: string;
    currency: string;
    legal_regime: string;
    debtor_name: string | null;
    holds: string[]; // active surendettement / collective proceeding holds
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
  notifications: Notification[];
  documents: { id: string; kind: string; created_at: string }[];
  other_files: { account_id: string; external_ref: string }[];
  // M2b-6
  refunds?: Refund[];
  bank_lines?: BankLine[];
};

export type Refund = {
  id: string;
  amount_minor: string;
  payee_name: string;
  payee_iban_end: string;
  payee_is_payer: boolean;
  end_to_end_id: string;
  reason_code: string;
  reason: string;
  status: string;
  requested_at: string;
  executed_on: string | null;
  cancelled_at: string | null;
  cancel_reason: string | null;
};

export type BankLine = {
  bank_transaction_id: string;
  kind: string;
  method: string;
  booking_date: string;
  amount_minor: string;
  direction: string;
  return_reason: string | null;
  statement_id: string;
  decided_at: string;
  reason: string | null;
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

/** What was allocated (forwards apart), forwarded and left of a payment, as text (integer minor units). */
export function positionFigures(position: PaymentDetail["position"]): {
  allocated: string;
  forwarded: string;
  unallocated: string;
} {
  const forwarded = BigInt(position.forwarded_minor);
  return {
    allocated: (BigInt(position.allocated_minor) - forwarded).toString(),
    forwarded: forwarded.toString(),
    unallocated: position.unallocated_minor,
  };
}

/** The file an allocation row belongs to, when it is not obviously the payment's own one (else null). */
export function rowFileLabel(rowFile: string | null, ownFile: string | null | undefined, liveFiles: number): string | null {
  if (!rowFile) return null;
  return liveFiles > 1 || rowFile !== ownFile ? rowFile : null;
}

/**
 * The order the allocation engine applies (worker `payments.allocation`), as it applies it; articles cited only for
 * what they say (1342-10: the debtor's designation, due debts first; 1343-1: interest first).
 */
export const APPLIED_ORDER =
  "Ordre appliqué : d'abord les factures désignées par le débiteur, puis les factures échues (art. 1342-10 C. civ.), " +
  "de la plus ancienne échéance à la plus récente (à échéance égale, au prorata), puis les factures non échues ; " +
  "dans chaque facture, les intérêts avant le principal (art. 1343-1 C. civ.).";

/** What « Désimputer » does, by the file reversed (the payment's own, or another file of the debtor). */
export function reverseEffect(o: { amount: string; fileRef: string; ownFile: boolean; othersRemain: boolean }): string {
  const head = `${o.amount} imputés sur le dossier ${o.fileRef} seront contre-passés à la date de l'imputation : les factures retrouvent leur solde. Notification enregistrée pour le client (envoi : à venir).`;
  if (!o.ownFile)
    return `${head} Ce montant redevient un trop-perçu du paiement : il n'est jamais reversé au client ; il sera remboursé au payeur, ou imputé sur un autre dossier du débiteur à sa demande écrite.`;
  if (o.othersRemain)
    return `${head} Le paiement attendra ensuite votre décision : réimputer sur ce dossier (l'imputation sur l'autre dossier reste en place).`;
  return `${head} Le paiement attendra ensuite votre décision (réimputer, ou désaffecter s'il ne concerne pas ce dossier).`;
}

/** Holds that block allocation, forwards and compensation (surendettement, collective proceeding). */
export function blockingHold(holds: { kind: string }[]): boolean {
  return holds.some((h) => h.kind === "surendettement" || h.kind === "collective_proceeding");
}

/** Reasons ops may send back to allocation from (« Imputer »). */
const REALLOCATE_FROM = new Set([
  "allocation_reversed",
  "nothing_due",
  "credit_note_to_apply",
  "before_servicing_start",
  "partial_return",
]);
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
    reverse: live.size > 0 && p.status !== "refund_pending", // a pending refund is cancelled first (M2b-6)
    allocate:
      (p.status === "matched" && p.review_reason !== null && REALLOCATE_FROM.has(p.review_reason)) ||
      // its own file's allocation reversed while another file keeps its share: back to its file
      (p.status === "partially_allocated" && p.review_reason === "allocation_reversed"),
    releaseHold: p.status === "matched" && p.review_reason === "hold_blocks_allocation",
    forward:
      allocated === BigInt(0) &&
      left > BigInt(0) &&
      p.status === "matched" &&
      (d.file?.holds ?? []).length === 0 && // a held file's payments are refunded, or allocated on authorisation
      (p.review_reason === "before_servicing_start" || d.file?.status === "closed_recalled"),
    otherFile:
      left > BigInt(0) &&
      d.other_files.length > 0 &&
      ((p.status === "partially_allocated" && p.review_reason === "overpayment") ||
        (p.status === "matched" && p.review_reason === "nothing_due")),
    // nothing allocated and nothing gone back out (a partial return keeps the payment on its file)
    unassign:
      p.status === "matched" &&
      allocated === BigInt(0) &&
      BigInt(d.position.returned_minor) === BigInt(0) &&
      p.account_id !== null,
  };
}

/** What « Imputer » does, by the reason the payment waits for (the sheet says it before anything is sent). */
export const REALLOCATE_TEXT: Record<string, string> = {
  allocation_reversed: "Le paiement sera imputé à nouveau sur ce dossier, dans l'ordre appliqué.",
  nothing_due: "Le paiement sera imputé sur ce dossier s'il présente à nouveau un solde ; sinon il reviendra ici.",
  credit_note_to_apply:
    "Le paiement sera imputé sans appliquer l'avoir du dossier (la compensation n'est pas invoquée).",
  before_servicing_start:
    "Le solde du cédant ne tient pas compte de ce paiement : il sera imputé à la date d'arrêté, dans l'ordre appliqué.",
  partial_return:
    "Ce qui reste du paiement après le retour partiel sera imputé sur ce dossier, à partir de la date du retour, dans l'ordre appliqué.",
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
  if (message.includes("nothing of this payment is allocated")) return "already_reversed";
  if (message.includes("the file is held")) return "file_held";
  if (
    message.includes("the payment changed") ||
    message.includes("is not held") ||
    message.includes("cannot be sent to allocation from here") ||
    message.includes("only what is left of a payment over its file") ||
    message.includes("nothing is left of this payment")
  )
    return "payment_changed";
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
    forwarded: boolean;
  }[];
  proposal: Proposal | null;
  // M2b-6: payments the debtor made to the client directly (the client's statement), and the file's documents
  direct_payments?: DirectPayment[];
  documents?: { id: string; kind: string; created_at: string }[] | null;
};

export type DirectPayment = {
  id: string;
  amount_minor: string;
  currency: string;
  paid_on: string;
  status: string;
  refusal_code: string | null;
  requested_at: string;
  reason: string | null;
  items: string[];
  lines: { item_ref: string; component: string; amount_minor: string }[];
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
