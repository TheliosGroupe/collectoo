import { money } from "@/lib/payments/statements";

// ---------------------------------------------------------------------------------------------------------------------
// M2c-7c-1 (plan docs/design/m2c-7-plan.md §5.5): what a client owes the servicer and what the servicer owes it back —
// « Ce que le client doit au cabinet » (public.client_open_documents), the « Enregistrer un règlement » sheet and its
// live effect (public.client_payment_preview: the SQL plan, never computed here), « Règlement d'une facture ou d'une
// avance du cabinet » on a dedicated-account line (public.client_payment_line), « Enregistrer le remboursement »
// (public.record_client_refund) and the client space's credits (public.client_space_credits). Every amount and date is
// SQL's, as text; these only word them. Refusals in French per code (« client payment refused: <code> »).
// ---------------------------------------------------------------------------------------------------------------------

const MINOR = /^-?\d{1,16}$/;
const ISO = /^\d{4}-\d{2}-\d{2}$/;
const isMinor = (v: unknown): v is string => typeof v === "string" && MINOR.test(v);
const isDay = (v: unknown): v is string => typeof v === "string" && ISO.test(v);
const isText = (v: unknown): v is string => typeof v === "string";
const isBool = (v: unknown): v is boolean => typeof v === "boolean";
const orNull = (v: unknown, test: (x: unknown) => boolean) => v === null || v === undefined || test(v);

function frenchDay(iso: string): string {
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

export type InFlightRun = { run_id: string; number: string } | null;
export type CreditCause = "overpayment" | "procedure";

export type OpenInvoice = {
  id: string;
  number: string;
  issue_date: string;
  due_date: string | null;
  settlement: string;
  ttc_minor: string;
  open_minor: string;
  pending_vat_minor: string;
  before_opening: boolean;
  payable: boolean;
  in_flight_run: InFlightRun;
};
export type OpenAdvance = {
  id: string;
  cause: string;
  created_on: string;
  born_on: string;
  amount_minor: string;
  open_minor: string;
  mandate_reference: string | null;
  recovery: string;
  clause_ref: string | null;
  before_opening: boolean;
  payable: boolean;
  in_flight_run: InFlightRun;
};
export type WrittenOffAdvance = {
  id: string;
  cause: string;
  born_on: string;
  written_off_on: string;
  written_off_minor: string;
  recovered_minor: string;
  available_minor: string;
  /** (review round 1, MONEY-1) born before the client's proceeding opened: the client may not repay it (L622-7 I). */
  before_opening: boolean;
  payable: boolean;
};
export type RefundOwed = { id: string; number: string; issue_date: string; owed_minor: string; in_flight_run: InFlightRun };
/** A credit owed back: created_on is its recording, received_on (review round 3) the day the money was received — its
 *  payment's entry's date (the value date on the own account, the line's booking date on the dedicated one). */
export type ClientCredit = {
  id: string;
  cause: CreditCause;
  created_on: string;
  received_on: string;
  amount_minor: string;
  open_minor: string;
};
export type OpenDocuments = {
  client_id: string;
  currency: string;
  today: string;
  procedure: boolean;
  own_account: boolean;
  invoices: OpenInvoice[];
  advances: OpenAdvance[];
  written_off: WrittenOffAdvance[];
  refunds_owed: RefundOwed[];
  credits: ClientCredit[];
  default_order: { document_kind: "invoice" | "advance"; document_id: string }[];
  default_open_minor: string;
};

function run(v: unknown): InFlightRun | undefined {
  if (v === null || v === undefined) return null;
  const r = v as Record<string, unknown>;
  return isText(r.run_id) && isText(r.number) ? { run_id: r.run_id, number: r.number } : undefined;
}

function list<T>(v: unknown, one: (x: Record<string, unknown>) => T | null): T[] | null {
  if (!Array.isArray(v)) return null;
  const out: T[] = [];
  for (const x of v) {
    if (!x || typeof x !== "object") return null;
    const r = one(x as Record<string, unknown>);
    if (!r) return null;
    out.push(r);
  }
  return out;
}

/** public.client_open_documents, or null when it is not its shape — never a guess. */
export function parseOpenDocuments(x: unknown): OpenDocuments | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  if (!isText(o.client_id) || !isText(o.currency) || !isDay(o.today) || !isBool(o.procedure) || !isBool(o.own_account))
    return null;
  if (!isMinor(o.default_open_minor)) return null;
  const invoices = list(o.invoices, (i) => {
    const r = run(i.in_flight_run);
    if (!isText(i.id) || !isText(i.number) || !isDay(i.issue_date) || !orNull(i.due_date, isDay) || !isText(i.settlement))
      return null;
    if (!isMinor(i.ttc_minor) || !isMinor(i.open_minor) || !isMinor(i.pending_vat_minor)) return null;
    if (!isBool(i.before_opening) || !isBool(i.payable) || r === undefined) return null;
    return { ...(i as unknown as OpenInvoice), due_date: (i.due_date as string | null | undefined) ?? null, in_flight_run: r };
  });
  const advances = list(o.advances, (a) => {
    const r = run(a.in_flight_run);
    if (!isText(a.id) || !isText(a.cause) || !isDay(a.created_on) || !isDay(a.born_on)) return null;
    if (!isMinor(a.amount_minor) || !isMinor(a.open_minor) || !isText(a.recovery)) return null;
    if (!orNull(a.mandate_reference, isText) || !orNull(a.clause_ref, isText)) return null;
    if (!isBool(a.before_opening) || !isBool(a.payable) || r === undefined) return null;
    return {
      ...(a as unknown as OpenAdvance),
      mandate_reference: (a.mandate_reference as string | null | undefined) ?? null,
      clause_ref: (a.clause_ref as string | null | undefined) ?? null,
      in_flight_run: r,
    };
  });
  const written = list(o.written_off, (w) =>
    isText(w.id) && isText(w.cause) && isDay(w.born_on) && isDay(w.written_off_on) && isMinor(w.written_off_minor) &&
    isMinor(w.recovered_minor) && isMinor(w.available_minor) && isBool(w.before_opening) && isBool(w.payable)
      ? (w as unknown as WrittenOffAdvance)
      : null,
  );
  const refunds = list(o.refunds_owed, (f) => {
    const r = run(f.in_flight_run);
    return isText(f.id) && isText(f.number) && isDay(f.issue_date) && isMinor(f.owed_minor) && r !== undefined
      ? { ...(f as unknown as RefundOwed), in_flight_run: r }
      : null;
  });
  const credits = list(o.credits, (c) =>
    isText(c.id) && (c.cause === "overpayment" || c.cause === "procedure") && isDay(c.created_on) &&
    isDay(c.received_on) && isMinor(c.amount_minor) && isMinor(c.open_minor)
      ? (c as unknown as ClientCredit)
      : null,
  );
  const order = list(o.default_order, (d) =>
    (d.document_kind === "invoice" || d.document_kind === "advance") && isText(d.document_id)
      ? { document_kind: d.document_kind as "invoice" | "advance", document_id: d.document_id }
      : null,
  );
  if (!invoices || !advances || !written || !refunds || !credits || !order) return null;
  return {
    client_id: o.client_id,
    currency: o.currency,
    today: o.today,
    procedure: o.procedure,
    own_account: o.own_account,
    invoices,
    advances,
    written_off: written,
    refunds_owed: refunds,
    credits,
    default_order: order,
    default_open_minor: o.default_open_minor,
  };
}

export type PaymentPart = {
  ord: number;
  document_kind: "invoice" | "advance" | "written_off" | "client_credit";
  document_id: string | null;
  number: string | null;
  amount_minor: string;
  vat_moved_minor: string;
  cause: CreditCause | null;
};
export type PaymentPreview = {
  amount_minor: string | null;
  open_minor: string;
  credit_minor: string;
  rows: PaymentPart[];
  refusal: string | null;
  refusal_detail: string | null;
};
const PART_KINDS = new Set(["invoice", "advance", "written_off", "client_credit"]);

/** public.client_payment_preview, or null when it is not its shape. */
export function parsePaymentPreview(x: unknown): PaymentPreview | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  if (!orNull(o.amount_minor, isMinor) || !isMinor(o.open_minor) || !isMinor(o.credit_minor)) return null;
  if (!orNull(o.refusal, isText) || !orNull(o.refusal_detail, isText)) return null;
  const rows = list(o.rows, (r) =>
    typeof r.ord === "number" && isText(r.document_kind) && PART_KINDS.has(r.document_kind) &&
    orNull(r.document_id, isText) && orNull(r.number, isText) && isMinor(r.amount_minor) && isMinor(r.vat_moved_minor) &&
    (r.cause === null || r.cause === undefined || r.cause === "overpayment" || r.cause === "procedure")
      ? {
          ord: r.ord,
          document_kind: r.document_kind as PaymentPart["document_kind"],
          document_id: (r.document_id as string | null | undefined) ?? null,
          number: (r.number as string | null | undefined) ?? null,
          amount_minor: r.amount_minor,
          vat_moved_minor: r.vat_moved_minor,
          cause: (r.cause as CreditCause | null | undefined) ?? null,
        }
      : null,
  );
  if (!rows) return null;
  return {
    amount_minor: (o.amount_minor as string | null | undefined) ?? null,
    open_minor: o.open_minor,
    credit_minor: o.credit_minor,
    rows,
    refusal: (o.refusal as string | null | undefined) ?? null,
    refusal_detail: (o.refusal_detail as string | null | undefined) ?? null,
  };
}

/**
 * The sheet's live effect, part by part, as SQL planned it: « FC-2026-000004 : 36,00 € réglés (dont TVA 6,00 €
 * devenue exigible) ; avance du 12/11/2026 : 200,00 € remboursés ; trop-perçu de 5,00 € à rembourser au client ». A
 * document the client may not pay ([critic] L21) is never said to be settled; a written-off advance repaid is a
 * recovery ([critic] M7-MONEY-10), (review round 1, MONEY-1) unless the client may not repay it: then it is held for the
 * procedure, never income; a surplus while the client's proceeding stands is held for the procedure (OQ-98).
 */
export function paymentEffect(p: PaymentPreview, docs: OpenDocuments): string {
  const cur = docs.currency;
  const parts: string[] = [];
  for (const r of p.rows) {
    const amount = money(r.amount_minor, cur);
    if (r.document_kind === "invoice") {
      const vat = BigInt(r.vat_moved_minor) > BigInt(0) ? ` (dont TVA ${money(r.vat_moved_minor, cur)} devenue exigible)` : "";
      parts.push(`${r.number ?? "Facture"} : ${amount} réglés${vat}`);
    } else if (r.document_kind === "advance") {
      const a = docs.advances.find((x) => x.id === r.document_id);
      parts.push(`avance${a ? ` du ${frenchDay(a.born_on)}` : ""} : ${amount} remboursés`);
    } else if (r.document_kind === "written_off") {
      const w = docs.written_off.find((x) => x.id === r.document_id);
      parts.push(
        `Avance passée en perte${w ? ` le ${frenchDay(w.written_off_on)}` : ""} : remboursement de ${amount} enregistré en recette (compte proposé 7714, OQ-88)`,
      );
    } else if (r.document_id) {
      const invoice = docs.invoices.find((x) => x.id === r.document_id);
      const advance = docs.advances.find((x) => x.id === r.document_id);
      const lost = docs.written_off.find((x) => x.id === r.document_id);
      if (!invoice && !advance && lost) {
        parts.push(
          `Avance passée en perte le ${frenchDay(lost.written_off_on)} : ${amount} — Créance antérieure à l'ouverture de la procédure du client : la somme n'est pas encaissée en recette ; elle est inscrite comme à rendre à la procédure (avis de l'avocat, OQ-98)`,
        );
      } else {
        const named = invoice?.number ?? (advance ? `avance du ${frenchDay(advance.born_on)}` : "document");
        parts.push(
          `${named} : ${amount} — Créance antérieure à l'ouverture de la procédure du client : la somme n'est pas imputée ; elle est inscrite comme à rendre à la procédure (avis de l'avocat, OQ-98)`,
        );
      }
    } else if (r.cause === "procedure") {
      parts.push(`${amount} inscrits comme à rendre à la procédure collective du client (avis de l'avocat, OQ-98)`);
    } else {
      parts.push(`trop-perçu de ${amount} à rembourser au client`);
    }
  }
  return parts.join(" ; ");
}

/**
 * (review round 1, TUI-2, CC-1) The inputs a preview is computed for: the amount as typed, the value date, and — with a
 * designation only, as the command sends them — the documents in the client's order and the losses it repays.
 */
export function previewInputs(x: {
  amount: string;
  valueDate: string;
  designated: boolean;
  named: readonly string[];
  recover: readonly string[];
}): string {
  return JSON.stringify([
    x.amount.trim(),
    x.valueDate,
    x.designated && x.named.length ? x.named : null,
    x.designated && x.recover.length ? x.recover : null,
  ]);
}

/** The preview the sheet may show and record on: only the one computed for the inputs as they now are, else none. */
export function currentPreview(
  stamped: { inputs: string; preview: PaymentPreview | null } | null,
  inputs: string,
): PaymentPreview | null {
  return stamped && stamped.inputs === inputs ? stamped.preview : null;
}

export type PaymentResult = {
  entry_id: string;
  settled: {
    document_kind: "invoice" | "advance" | "written_off";
    document_id: string;
    number: string | null;
    amount_minor: string;
    vat_moved_minor: string;
  }[];
  credit_minor: string;
  credits: { cause: CreditCause; amount_minor: string }[];
};

/** record_client_payment's and book_client_payment_line's result, or null when it is not its shape. */
export function parsePaymentResult(x: unknown): PaymentResult | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  if (!isText(o.entry_id) || !isMinor(o.credit_minor)) return null;
  const settled = list(o.settled, (r) =>
    (r.document_kind === "invoice" || r.document_kind === "advance" || r.document_kind === "written_off") &&
    isText(r.document_id) && orNull(r.number, isText) && isMinor(r.amount_minor) && isMinor(r.vat_moved_minor)
      ? {
          document_kind: r.document_kind as PaymentResult["settled"][number]["document_kind"],
          document_id: r.document_id,
          number: (r.number as string | null | undefined) ?? null,
          amount_minor: r.amount_minor,
          vat_moved_minor: r.vat_moved_minor,
        }
      : null,
  );
  const credits = list(o.credits, (c) =>
    (c.cause === "overpayment" || c.cause === "procedure") && isMinor(c.amount_minor)
      ? { cause: c.cause as CreditCause, amount_minor: c.amount_minor }
      : null,
  );
  return settled && credits ? { entry_id: o.entry_id, settled, credit_minor: o.credit_minor, credits } : null;
}

/** (review round 1, TUI-2, CC-1) What the command posted, worded as the effect was: never the preview's amounts. */
export function resultEffect(r: PaymentResult, docs: OpenDocuments): string {
  const rows: PaymentPart[] = [
    ...r.settled.map((x, i) => ({ ord: i + 1, ...x, cause: null })),
    ...r.credits.map((c, i) => ({
      ord: r.settled.length + i + 1,
      document_kind: "client_credit" as const,
      document_id: null,
      number: null,
      amount_minor: c.amount_minor,
      vat_moved_minor: "0",
      cause: c.cause,
    })),
  ];
  return paymentEffect(
    { amount_minor: null, open_minor: "0", credit_minor: r.credit_minor, rows, refusal: null, refusal_detail: null },
    docs,
  );
}

/** « Ce que le client doit au cabinet »'s row of an advance passed as a loss (review round 1, MONEY-1). */
export function writtenOffLine(w: WrittenOffAdvance, currency: string): string {
  const head = `Avance du ${frenchDay(w.born_on)} passée en perte le ${frenchDay(w.written_off_on)}`;
  return w.payable
    ? `${head} : ${money(w.available_minor, currency)} que le client peut encore rembourser (enregistré en recette, compte proposé 7714, OQ-88)`
    : `${head} (reste ${money(w.available_minor, currency)}) : créance antérieure à l'ouverture de la procédure du client ; une somme reçue pour elle n'est pas encaissée en recette, elle est mise de côté pour la procédure (avis de l'avocat, OQ-98)`;
}

/** The sheet's choice of an advance passed as a loss the client repays (review round 1, MONEY-1). */
export function writtenOffChoice(w: WrittenOffAdvance, currency: string): string {
  return w.payable
    ? `Avance passée en perte le ${frenchDay(w.written_off_on)} (${money(w.available_minor, currency)} à recouvrer)`
    : `Avance passée en perte le ${frenchDay(w.written_off_on)} (${money(w.available_minor, currency)} ; créance antérieure à l'ouverture de la procédure : mise de côté pour la procédure)`;
}

/** (M2c-7c-2 review round 1, MONEY-2) What the dedicated line's sheet says when its label designates nothing. */
export const NO_DESIGNATION =
  "Le libellé ne désigne aucune facture ni demande de remboursement : ordre par défaut (factures échues, avances, autres factures).";

/**
 * (review round 1, TUI-3) The dedicated line's sentence on what its label designates, from SQL's plan: a named invoice
 * is « imputé » only when a part settles it; a pre-opening one (L622-7 I) is never; one the amount does not reach is
 * said so. Null when the label designates nothing. (M2c-7c-2 review round 1, MONEY-2) An advance the label designates
 * by naming its repayment request (public.client_payment_line's `named_requests`) reads « l'avance du JJ/MM/AAAA
 * (demande DRA-…) ».
 */
export function designationSentence(
  named: readonly string[],
  p: PaymentPreview | null,
  docs: OpenDocuments,
  requests: readonly { number: string; advance_ids: readonly string[] }[] = [],
): string | null {
  if (named.length === 0) return null;
  const advanceName = (id: string): string | null => {
    const a = docs.advances.find((x) => x.id === id);
    const q = requests.find((r) => r.advance_ids.includes(id));
    if (!a) return null;
    return q ? `l'avance du ${frenchDay(a.born_on)} (demande ${q.number})` : `l'avance du ${frenchDay(a.born_on)}`;
  };
  const parts = named.map((id) => {
    const number = docs.invoices.find((i) => i.id === id)?.number ?? advanceName(id) ?? "document";
    const row = p?.rows.find((r) => r.document_id === id);
    if (row?.document_kind === "client_credit")
      return `${number} : créance antérieure à l'ouverture de la procédure du client, la somme n'est pas imputée`;
    if (row) return `${number} : le règlement lui est imputé`;
    return `${number} : rien ne lui est imputé`;
  });
  return `Le libellé désigne ${parts.join(" ; ")}.`;
}

/**
 * (review round 1, TUI-3) Where a dedicated line's money goes once booked: all of it swept to the own account with the
 * next quote-part; what SQL's plan holds back (a credit owed back) stays owed from there — to the client, or to its
 * procedure — never « revient au cabinet ».
 */
export function dedicatedLineEffect(p: PaymentPreview | null, currency: string): string {
  const owed = (cause: CreditCause) =>
    (p?.rows ?? [])
      .filter((r) => r.document_kind === "client_credit" && r.cause === cause)
      .reduce((s, r) => s + BigInt(r.amount_minor), BigInt(0));
  const procedure = owed("procedure");
  const client = owed("overpayment");
  if (procedure === BigInt(0) && client === BigInt(0)) return DEDICATED_LINE_EFFECT;
  const held = [
    procedure > BigInt(0) ? `${money(procedure.toString(), currency)} y restent à rendre à la procédure collective du client` : null,
    client > BigInt(0) ? `${money(client.toString(), currency)} y restent à rembourser au client` : null,
  ].filter(Boolean);
  return `La somme sera virée sur le compte propre du cabinet avec la prochaine quote-part ; ${held.join(" ; ")}.`;
}

/** The refusal's code read from the database's message (« client payment refused: not_open »), or null. */
export function refusalCode(message: string): string | null {
  const m = /^client (?:payment|refund) refused: ([a-z_]+)$/.exec(message.trim());
  return m ? m[1] : null;
}

const CHANGED = "Les montants ont changé depuis l'affichage : rechargez la page.";
const NOT_ALLOWED = "Action réservée aux administrateurs et responsables des opérations (double authentification).";
const BUSY = "Opération en cours sur les encaissements du cabinet : réessayez dans un instant.";

/**
 * « Enregistrer un règlement » and the dedicated line's refusals, in French (detail: an in-flight run's number; (review
 * round 4) for bad_date, the day a designated document or loss came into being, when SQL names one — else the date is in
 * the future). On the dedicated line (`origin` "line", review round 1 TUI-7) the label is the designation: never
 * « sans désigner ».
 */
export function clientPaymentRefusal(message: string, detail?: string | null, origin: "sheet" | "line" = "sheet"): string {
  if (message === "not allowed") return NOT_ALLOWED;
  if (/allocation_busy|lock timeout|could not obtain lock/.test(message)) return BUSY;
  const code = refusalCode(message);
  if (code === "bad_date" && isDay(detail))
    return origin === "line"
      ? `Ce crédit a été reçu avant le ${frenchDay(detail)}, jour où naît un document désigné : il ne peut pas le régler.`
      : `Un document ou une perte désignés n'existaient pas encore à cette date de valeur : désigné ainsi, le règlement ne peut pas être daté avant le ${frenchDay(detail)}.`;
  if (origin === "line" && code === "in_flight")
    return `Le libellé désigne un document que le reversement ${detail || "en cours"} en cours règle déjà : attendez son débit.`;
  if (origin === "line" && code === "not_open")
    return "Un document que désigne le libellé n'a plus rien à régler : rechargez la page.";
  switch (code) {
    case "designation_evidence_required":
      return "Joignez la pièce où le client désigne ce qu'il règle ; sinon l'ordre par défaut s'applique.";
    case "in_flight":
      return `Ce document est déjà réglé par le reversement ${detail || "en cours"} en cours : attendez son débit, ou enregistrez le règlement sans désigner de document.`;
    case "not_open":
      return "Ce document (ou cette avance) n'a plus rien à régler : enregistrez le règlement sans le désigner ; la somme sera inscrite en trop-perçu à rembourser.";
    case "open_changed":
      return CHANGED;
    case "no_own_account":
      return "Aucun compte propre n'est enregistré (Paramètres › Facturation).";
    case "evidence_required":
      return "Joignez la preuve du virement.";
    case "bad_amount":
      return "Montant invalide (en euros, deux décimales au plus).";
    case "bad_date":
      return "La date ne peut pas être dans le futur.";
    case "reason_required":
      return "Indiquez un motif.";
    case "not_a_client_credit":
      return "Ce crédit ne vient pas du compte de reversement d'un client : utilisez une autre action.";
    case "line_booked":
      return "Cette ligne est déjà comptabilisée.";
    case "our_reference":
      return "Cette ligne porte la référence de l'un de nos virements : c'est ce virement qui revient.";
    case "ambiguous_client":
      return "Cet IBAN est le compte de reversement de plusieurs clients : prévenez le support.";
    default:
      return "Le règlement n'a pas pu être enregistré. Rechargez la page et réessayez.";
  }
}

/**
 * « Enregistrer le remboursement »'s refusals, in French, with what is still owed (detail: an in-flight run; (review
 * round 4) for bad_date, the earliest day SQL allows — a credit's receipt, a credit note's issue — else the date is in
 * the future).
 */
export function clientRefundRefusal(
  message: string,
  ctx: { owed_minor: string; currency: string; kind: "credit_note" | "client_credit"; cause?: CreditCause | null },
  detail?: string | null,
): string {
  if (message === "not allowed") return NOT_ALLOWED;
  if (/allocation_busy|lock timeout|could not obtain lock/.test(message)) return BUSY;
  // (review round 1, TUI-4) a sum held for the procedure is rendered to it, never « trop-perçu » nor the client's
  const held = ctx.kind === "client_credit" && ctx.cause === "procedure";
  switch (refusalCode(message)) {
    case "nothing_owed":
      if (held) return "Cette somme mise de côté pour la procédure est déjà rendue.";
      return ctx.kind === "credit_note" ? "Cet avoir ne doit plus rien au client." : "Ce trop-perçu est déjà remboursé.";
    case "amount_exceeds_owed":
      if (held) return `Le montant dépasse ce qui reste à rendre à la procédure (${money(ctx.owed_minor, ctx.currency)}).`;
      return ctx.kind === "credit_note"
        ? `Le montant dépasse ce que l'avoir doit encore au client (${money(ctx.owed_minor, ctx.currency)}).`
        : `Le montant dépasse ce qui reste à rembourser au client (${money(ctx.owed_minor, ctx.currency)}).`;
    case "owed_changed":
      return CHANGED;
    case "in_flight":
      return `Déjà réglé par le reversement ${detail || "en cours"} en cours : attendez son débit.`;
    case "bad_date":
      if (isDay(detail))
        return `Le virement ne peut pas être daté avant le ${frenchDay(detail)}, ${
          ctx.kind === "credit_note" ? "jour où l'avoir a été émis" : "jour où la somme a été reçue"
        }.`;
      return "La date ne peut pas être dans le futur.";
    case "evidence_required":
      return "Joignez la preuve du virement de remboursement.";
    case "no_own_account":
      return "Aucun compte propre n'est enregistré (Paramètres › Facturation).";
    case "bad_amount":
      return "Montant invalide (en euros, deux décimales au plus).";
    default:
      return "Le remboursement n'a pas pu être enregistré. Rechargez la page et réessayez.";
  }
}

/** « Débits et retours », a client's credit: where its money goes once booked as « Règlement du client ». */
export const DEDICATED_LINE_EFFECT =
  "La somme revient au cabinet : elle sera virée sur son compte propre avec la prochaine quote-part.";

/** A credit owed back, as staff read it on the client's page: dated (review round 3) by the money's receipt, never
 *  its recording. */
export function creditLabel(c: ClientCredit): string {
  return c.cause === "overpayment"
    ? `Trop-perçu du ${frenchDay(c.received_on)}`
    : `Somme reçue le ${frenchDay(c.received_on)}, mise de côté pour la procédure collective du client (avis de l'avocat, OQ-98)`;
}

/** (review round 1, TUI-4) A credit's open part by its payee: the client's, or its procedure's (plan §5.2.6). */
export function creditOwedText(c: ClientCredit, currency: string): string {
  return c.cause === "overpayment"
    ? `${money(c.open_minor, currency)} à rembourser`
    : `${money(c.open_minor, currency)} à rendre à la procédure`;
}

/**
 * (review round 1, TUI-4) The client page's credits by payee: what the servicer owes back to the client (its overpaid
 * sums, under the credit notes' refunds) apart from what it holds for the client's procedure — the latter goes to the
 * administrator, mandataire or liquidator named in the evidence (plan §5.2.6, OQ-98), never « au client ».
 */
export function staffCreditGroups(docs: OpenDocuments): {
  client: ClientCredit[];
  procedure: ClientCredit[];
  clientTitle: string;
  procedureTitle: string;
} {
  return {
    client: docs.credits.filter((c) => c.cause === "overpayment"),
    procedure: docs.credits.filter((c) => c.cause === "procedure"),
    clientTitle: "Ce que le cabinet doit rembourser au client",
    procedureTitle: "Sommes mises de côté pour la procédure collective du client",
  };
}

/** « Enregistrer le remboursement »'s header: what is owed and to whom (review round 1, TUI-4). */
export function refundHeader(a: { title: string; owed_minor: string; currency: string; cause: CreditCause | null }): string {
  const to =
    a.cause === "procedure"
      ? "à rendre à la procédure (administrateur, mandataire ou liquidateur nommé dans la preuve)"
      : "à rembourser au client";
  return `${a.title} · ${money(a.owed_minor, a.currency)} ${to}, par virement depuis le compte propre du cabinet`;
}

export type SpaceCredit = {
  credit_id: string;
  currency: string;
  cause: CreditCause;
  created_on: string;
  /** (review round 3) the day the money was received (its payment's entry's date) */
  received_on: string;
  open_minor: string;
};
export type SpaceCredits = { rows: SpaceCredit[]; total: { currency: string; open_minor: string }[] };

/** public.client_space_credits, or null when it is not its shape. */
export function parseClientSpaceCredits(x: unknown): SpaceCredits | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  const rows = list(o.rows, (r) =>
    isText(r.credit_id) && isText(r.currency) && (r.cause === "overpayment" || r.cause === "procedure") &&
    isDay(r.created_on) && isDay(r.received_on) && isMinor(r.open_minor)
      ? (r as unknown as SpaceCredit)
      : null,
  );
  const total = list(o.total, (t) => (isText(t.currency) && isMinor(t.open_minor) ? { currency: t.currency, open_minor: t.open_minor } : null));
  return rows && total ? { rows, total } : null;
}

/**
 * The client space's lines: what the servicer owes the client back (« Trop-perçu du JJ/MM/AAAA : X € que le cabinet
 * vous doit »); a sum held for its collective proceeding is stated as such, never as owed to it (OQ-98). (Review round
 * 3) Each is dated by the day the money was received (received_on), never by its recording.
 */
export function clientSpaceCreditLines(c: SpaceCredits): string[] {
  return c.rows.map((r) =>
    r.cause === "overpayment"
      ? `Trop-perçu du ${frenchDay(r.received_on)} : ${money(r.open_minor, r.currency)} que le cabinet vous doit`
      : `Somme reçue le ${frenchDay(r.received_on)}, mise de côté pour votre procédure collective : ${money(r.open_minor, r.currency)}`,
  );
}

export type CreditSection = { title: string; testId: string; lines: { id: string; text: string }[]; note: string | null };

/**
 * (review round 1, TUI-1) The client space's credit sections, each titled by what it holds: « Sommes que le cabinet
 * vous doit » over its overpaid sums only; a sum held for its collective proceeding under « Sommes reçues pendant votre
 * procédure collective », never « vous doit » (plan §5.2.6: it goes to the procedure; OQ-98).
 */
export function clientSpaceCreditSections(c: SpaceCredits): CreditSection[] {
  const text = clientSpaceCreditLines(c);
  const rows = c.rows.map((r, i) => ({ cause: r.cause, line: { id: r.credit_id, text: text[i] } }));
  const owed = rows.filter((r) => r.cause === "overpayment").map((r) => r.line);
  const held = rows.filter((r) => r.cause === "procedure").map((r) => r.line);
  const out: CreditSection[] = [];
  if (owed.length > 0)
    out.push({
      title: "Sommes que le cabinet vous doit",
      testId: "client-space-credits",
      lines: owed,
      note: "Le cabinet rembourse un trop-perçu par virement depuis son compte propre.",
    });
  if (held.length > 0)
    out.push({ title: "Sommes reçues pendant votre procédure collective", testId: "client-space-procedure-credits", lines: held, note: null });
  return out;
}
