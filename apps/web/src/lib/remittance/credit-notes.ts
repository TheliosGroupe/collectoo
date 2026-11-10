import type { ErrorCode } from "@/lib/boarding/forms";
import { money } from "@/lib/payments/statements";
import { frenchDate } from "@/lib/remittance/runs";

/**
 * M2c-5b « Émettre un avoir » (design §14.1, risk R2): the words of a manual credit note — its reason categories, why an
 * invoice cannot take one, the effect sheet, the refusals — and the client list's « rectifie la facture … ». Every
 * amount comes from the database as text in minor units (`public.credit_note_preview`, the same plan as the command):
 * the page never computes a VAT, a share or a remainder.
 */

/** The reason categories the credit note states (never the staff's free text, which stays with money staff). */
export const REASON_CATEGORIES: { code: string; label: string }[] = [
  { code: "terms_error", label: "Erreur de conditions de rémunération (taux, paliers ou minimum)" },
  { code: "basis_error", label: "Erreur d'assiette (encaissement non commissionnable)" },
  { code: "billing_error", label: "Erreur de facturation" },
];

export type InvoiceDetail = {
  id: string;
  number: string;
  kind: "invoice" | "credit_note";
  reason: string;
  issue_date: string;
  client_id: string;
  client_name: string | null;
  mandate_reference: string | null;
  run_id: string | null;
  run_number: string | null;
  service_from: string | null;
  service_to: string | null;
  settlement: string;
  due_date: string | null;
  ht: string;
  vat: string;
  ttc: string;
  vat_rate: string | null;
  credited_ht: string;
  remaining_ht: string;
  open_ttc: string;
  pending_vat: string;
  files: { account_id: string; reference: string | null; open_ht: string; waived_ht: string }[];
  file_count: number;
  credit_notes: {
    id: string;
    number: string;
    issue_date: string;
    reason: string;
    ht: string;
    vat: string;
    run_number: string | null;
    reason_code: string | null;
    reason_text: string | null;
    reason_fr: string | null;
  }[];
  refusal: string | null;
  can_credit: boolean;
};

export type CreditNotePreview = {
  refusal: string | null;
  number?: string;
  vat_rate?: string;
  ht?: string;
  vat?: string;
  ttc?: string;
  vat_pending?: string;
  vat_collected?: string;
  applied?: string;
  excess?: string;
  open_before?: string;
  open_after?: string;
  remaining_ht?: string;
  remaining_after?: string;
  selected_ht?: string;
  allocations?: { account_id: string; tier_key: string; ht: string }[];
};

const REFUSAL_TEXT: Record<string, string> = {
  credit_note: "Un avoir ne se rectifie pas par un autre avoir.",
  nothing_left: "Cette facture est déjà entièrement rectifiée : il ne reste rien à créditer.",
  in_flight:
    "Un reversement validé compense cette facture sur son virement, pas encore débité : attendez son débit, ou annulez ce reversement, avant d'émettre un avoir.",
  file_not_on_invoice: "Ce dossier n'a plus rien de facturé sur cette facture.",
  amount_required: "Indiquez un montant HT positif, au centime près.",
  more_than_remaining: "Le montant dépasse ce qui reste facturé (sur la facture, ou sur le dossier choisi).",
  unknown_invoice: "Facture introuvable.",
};

/** Why the invoice cannot take a manual credit note now (`commission_invoice_detail.refusal`, the plan's). */
export function refusalText(refusal: string | null): string | null {
  return refusal ? (REFUSAL_TEXT[refusal] ?? "Avoir impossible pour l'instant.") : null;
}

/** The refusals of `issue_credit_note` (« credit note refused: … ») and its locks, as codes. */
const CREDIT_ERRORS: [string, ErrorCode][] = [
  ["not allowed", "not_allowed"],
  ["refused: credit_note", "credit_note_on_credit_note"],
  ["refused: nothing_left", "credit_note_nothing_left"],
  ["refused: in_flight", "credit_note_in_flight"],
  ["refused: file_not_on_invoice", "credit_note_file"],
  ["refused: amount_required", "credit_note_amount"],
  ["refused: more_than_remaining", "credit_note_too_much"],
  ["refused: invoice_changed", "credit_note_changed"],
  ["refused: reason_code", "credit_note_category"],
  ["refused: reason_required", "reason_required"],
  ["allocation_busy", "run_busy"],
  ["could not obtain lock", "run_busy"],
  ["lock timeout", "run_busy"],
  ["the day turned", "run_retry"],
];

export function creditNoteErrorCode(message: string): ErrorCode {
  for (const [needle, code] of CREDIT_ERRORS) if (message.includes(needle)) return code;
  return "unknown";
}

const MINOR = /^-?\d+$/;

/**
 * The effect sheet (« Voir l'effet »): the credit note's HT, VAT and TTC, what it takes off what the invoice owes now and
 * the refund owed beyond it, and what the invoice still charges and owes after — all as the database computed them.
 * Null when the preview is not one (a refusal, or a field missing).
 */
export function effectLines(p: CreditNotePreview | null, currency = "EUR"): { label: string; value: string }[] | null {
  if (!p || p.refusal) return null;
  const fields = [p.ht, p.vat, p.ttc, p.applied, p.excess, p.remaining_after, p.open_after, p.vat_pending, p.vat_collected];
  if (fields.some((x) => x === undefined || !MINOR.test(x))) return null;
  const rows = [
    { label: "Avoir HT", value: money(p.ht!, currency) },
    { label: `TVA ${p.vat_rate ? percent(p.vat_rate) : ""}`.trim(), value: money(p.vat!, currency) },
    { label: "Avoir TTC", value: money(p.ttc!, currency) },
    { label: "Déduit de ce que la facture doit", value: money(p.applied!, currency) },
  ];
  if (BigInt(p.excess!) > BigInt(0)) {
    rows.push({ label: "À rembourser au client (avec un prochain reversement)", value: money(p.excess!, currency) });
  }
  rows.push(
    { label: "La facture devra encore (TTC)", value: money(p.open_after!, currency) },
    { label: "Reste facturé après l'avoir (HT)", value: money(p.remaining_after!, currency) },
  );
  return rows;
}

/** Where the credit note's VAT comes off: the invoice's pending VAT first (44574), the rest off the VAT already due. */
export function vatSplitText(p: CreditNotePreview | null, currency = "EUR"): string | null {
  if (!p || p.refusal || !p.vat_pending || !p.vat_collected) return null;
  if (!MINOR.test(p.vat_pending) || !MINOR.test(p.vat_collected)) return null;
  const parts: string[] = [];
  if (BigInt(p.vat_pending) > BigInt(0)) parts.push(`${money(p.vat_pending, currency)} sur la TVA en attente (44574)`);
  if (BigInt(p.vat_collected) > BigInt(0)) parts.push(`${money(p.vat_collected, currency)} sur la TVA exigible (44571)`);
  return parts.length > 0 ? `TVA de l'avoir : ${parts.join(", ")}.` : null;
}

/** « 20 % », « 5,5 % » from a rate as stored ("0.2000"). */
export function percent(rate: string): string {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(rate);
  if (!m) return rate;
  const scaled = BigInt(m[1]) * BigInt(10000) + BigInt((m[2] ?? "").padEnd(4, "0").slice(0, 4) || "0");
  const whole = scaled / BigInt(100);
  const frac = (scaled % BigInt(100)).toString().padStart(2, "0").replace(/0+$/, "");
  return `${whole}${frac ? `,${frac}` : ""} %`;
}

/**
 * A credit note in the client « Factures » list (289 I 5: it names the invoice it rectifies): « rectifie la facture
 * FC-… du … », and for a manual one its reason category, as its line states it (the part after « — »).
 */
export function creditNoteText(
  note: { kind: string; reason: string | null; designation: string | null },
  corrected: { number: string; issue_date: string }[],
): string | null {
  if (note.kind !== "credit_note" || corrected.length === 0) return null;
  const list = corrected.map((c) => `${c.number} du ${frenchDate(c.issue_date)}`).join(", ");
  const head = corrected.length > 1 ? `rectifie les factures ${list}` : `rectifie la facture ${list}`;
  if (note.reason !== "manual" || !note.designation) return head;
  const why = note.designation.split(" — ").slice(1).join(" — ").trim();
  return why ? `${head} · ${why}` : head;
}
