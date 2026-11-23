import { money } from "@/lib/payments/statements";

// ---------------------------------------------------------------------------------------------------------------------
// M2c-7b (plan docs/design/m2c-7-plan.md §4.3): the advances of the servicer — the « Avances » page, the « Passer en
// perte » sheet, the client space, the chip on the Reversements cards. Every amount and date comes from SQL as text
// (public.client_advances, public.client_space_advances: private.advance_open, the recording dates in Paris, and — review
// round 2 — each advance's birth, private.advance_born_on, the date its recovery's barred rule reads and the advance's
// date on every page); these only word them. LEX-28: toward the client, a write-off is never worded « abandon » nor « remise » — the client space
// shows only what is still claimed.
// ---------------------------------------------------------------------------------------------------------------------

export type AdvanceCause = "remitted_reversal" | "payout_overrun" | "double_payout";
/** How SQL says an advance is recovered (private.advance_recovery_of): its mandate's claw-back clause, a request (no
 *  clause, or no single mandate), or (review round 1, M7B-MONEY-2) neither — born before the client's proceeding opened,
 *  it is never set off (the prepare's rule). */
export type AdvanceRecovery = "clawback" | "request" | "request_no_mandate" | "barred_proceeding";

export type AdvanceRow = {
  advance_id: string;
  client_id: string;
  client_name: string;
  currency: string;
  cause: AdvanceCause;
  created_at: string;
  created_on: string;
  /** (review round 2) the advance's date: its entry's (private.advance_born_on), never later than its recording */
  born_on: string;
  cause_on: string;
  file_ref: string | null;
  amount_minor: string;
  recovered: { compensation: string; payment_own: string; payment_dedicated: string; write_off: string };
  open_minor: string;
  reversed: boolean;
  mandate_id: string | null;
  mandate_reference: string | null;
  recovery: AdvanceRecovery;
  clause_ref: string | null;
  in_flight_run: { run_id: string; number: string } | null;
};

export type ClientAdvances = {
  rows: AdvanceRow[];
  next: { created_at: string; id: string } | null;
  totals: { client_id: string; currency: string; open_minor: string }[];
  can_write_off: boolean;
};

const MINOR = /^-?\d{1,16}$/;
const ISO = /^\d{4}-\d{2}-\d{2}$/;
const CAUSES = new Set(["remitted_reversal", "payout_overrun", "double_payout"]);
const RECOVERIES = new Set(["clawback", "request", "request_no_mandate", "barred_proceeding"]);

function frenchDay(iso: string): string {
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

const isMinor = (v: unknown): v is string => typeof v === "string" && MINOR.test(v);
const isDay = (v: unknown): v is string => typeof v === "string" && ISO.test(v);
const isText = (v: unknown): v is string => typeof v === "string";
const orNull = (v: unknown, test: (x: unknown) => boolean) => v === null || v === undefined || test(v);

function parseRow(x: unknown): AdvanceRow | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  const r = o.recovered as Record<string, unknown> | null;
  if (!isText(o.advance_id) || !isText(o.client_id) || !isText(o.client_name) || !isText(o.currency)) return null;
  if (!isText(o.cause) || !CAUSES.has(o.cause) || !isText(o.recovery) || !RECOVERIES.has(o.recovery)) return null;
  if (!isText(o.created_at) || !isDay(o.created_on) || !isDay(o.born_on) || !isDay(o.cause_on)) return null;
  if (!isMinor(o.amount_minor) || !isMinor(o.open_minor) || typeof o.reversed !== "boolean") return null;
  if (!r || typeof r !== "object" || !["compensation", "payment_own", "payment_dedicated", "write_off"].every((k) => isMinor(r[k])))
    return null;
  if (!orNull(o.file_ref, isText) || !orNull(o.mandate_reference, isText) || !orNull(o.clause_ref, isText)) return null;
  const run = o.in_flight_run as Record<string, unknown> | null | undefined;
  if (run !== null && run !== undefined && (!isText(run.run_id) || !isText(run.number))) return null;
  return {
    advance_id: o.advance_id,
    client_id: o.client_id,
    client_name: o.client_name,
    currency: o.currency,
    cause: o.cause as AdvanceCause,
    created_at: o.created_at,
    created_on: o.created_on,
    born_on: o.born_on,
    cause_on: o.cause_on,
    file_ref: (o.file_ref as string | null | undefined) ?? null,
    amount_minor: o.amount_minor,
    recovered: r as AdvanceRow["recovered"],
    open_minor: o.open_minor,
    reversed: o.reversed,
    mandate_id: (o.mandate_id as string | null | undefined) ?? null,
    mandate_reference: (o.mandate_reference as string | null | undefined) ?? null,
    recovery: o.recovery as AdvanceRecovery,
    clause_ref: (o.clause_ref as string | null | undefined) ?? null,
    in_flight_run: run ? { run_id: run.run_id as string, number: run.number as string } : null,
  };
}

/** public.client_advances, or null when it is not its shape — never a guess. */
export function parseClientAdvances(x: unknown): ClientAdvances | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  if (!Array.isArray(o.rows) || !Array.isArray(o.totals) || typeof o.can_write_off !== "boolean") return null;
  const rows: AdvanceRow[] = [];
  for (const v of o.rows) {
    const r = parseRow(v);
    if (!r) return null;
    rows.push(r);
  }
  const totals: ClientAdvances["totals"] = [];
  for (const v of o.totals) {
    const t = v as Record<string, unknown>;
    if (!t || !isText(t.client_id) || !isText(t.currency) || !isMinor(t.open_minor)) return null;
    totals.push({ client_id: t.client_id, currency: t.currency, open_minor: t.open_minor });
  }
  const n = o.next as Record<string, unknown> | null | undefined;
  if (n !== null && n !== undefined && (!isText(n.created_at) || !isText(n.id))) return null;
  return { rows, next: n ? { created_at: n.created_at as string, id: n.id as string } : null, totals, can_write_off: o.can_write_off };
}

/** (review round 2, advance-date-contradicts-barred) « Née le » on the « Avances » page: the advance's birth (the date
 *  its recovery's barred rule reads), and its recording date apart, labelled so, when it is another day. */
export function advanceDates(r: Pick<AdvanceRow, "born_on" | "created_on">): { born: string; recorded: string | null } {
  return {
    born: frenchDay(r.born_on),
    recorded: r.created_on === r.born_on ? null : `enregistrée le ${frenchDay(r.created_on)}`,
  };
}

const ORIGIN: Record<AdvanceCause, string> = {
  remitted_reversal: "Paiement repris après reversement",
  payout_overrun: "Reversement au-delà du dû",
  double_payout: "Virement hors reversement",
};

/** « Origine » on the « Avances » page (plan §4.3): the file of a remitted collection taken back. */
export function advanceOrigin(r: Pick<AdvanceRow, "cause" | "file_ref">): string {
  const o = ORIGIN[r.cause];
  return r.cause === "remitted_reversal" && r.file_ref ? `${o} (dossier ${r.file_ref})` : o;
}

/** « Récupération »: the claw-back clause and its reference, a request (no clause, or no single mandate: founder Q2), the
 *  run in flight that takes it back, or (review round 1) no claw-back for one born before the client's proceeding. */
export function advanceRecovery(r: Pick<AdvanceRow, "recovery" | "clause_ref" | "in_flight_run">): string {
  if (r.in_flight_run) return `Reprise par ${r.in_flight_run.number} en cours`;
  if (r.recovery === "clawback")
    return r.clause_ref
      ? `Reprise sur les prochains reversements (${r.clause_ref} du mandat)`
      : "Reprise sur les prochains reversements (clause de reprise du mandat)";
  if (r.recovery === "barred_proceeding")
    return "Pas de reprise : avance née avant l'ouverture de la procédure collective du client";
  if (r.recovery === "request_no_mandate") return "Demande de remboursement (avance rattachée à aucun mandat unique)";
  return "Demande de remboursement (pas de clause de reprise)";
}

const big = (v: string) => (MINOR.test(v) ? BigInt(v) : BigInt(0));

/** What was recovered of an advance — its compensations and the client's payments; never what was passed as a loss
 *  (review round 1, tests-ui-3: shown apart, `recovered.write_off`). Staff only. */
export function advanceRecovered(r: Pick<AdvanceRow, "recovered">): string {
  const { compensation, payment_own, payment_dedicated } = r.recovered;
  return String(big(compensation) + big(payment_own) + big(payment_dedicated));
}

/** (review round 1, tests-ui-3) « Récupération »: what became of an advance — released with what it covered, settled
 *  (by a loss in full or in part, never « Récupérée » then), recovered, or how what is open is recovered. */
export function advanceStatus(
  r: Pick<AdvanceRow, "reversed" | "open_minor" | "amount_minor" | "recovered" | "currency" | "recovery" | "clause_ref" | "in_flight_run">,
): string {
  if (r.reversed) return "Annulée avec ce qu'elle couvrait";
  if (big(r.open_minor) > BigInt(0)) return advanceRecovery(r);
  const lost = big(r.recovered.write_off);
  if (lost > BigInt(0) && lost === big(r.amount_minor)) return "Soldée (passée en perte)";
  if (lost > BigInt(0)) return `Soldée (dont ${money(r.recovered.write_off, r.currency)} passés en perte)`;
  return "Récupérée";
}

/** The chip of a Reversements card (design §17 #1): only while something is open. */
export function advanceChip(openMinor: string | null | undefined, currency: string): string | null {
  if (!openMinor || !MINOR.test(openMinor) || BigInt(openMinor) <= BigInt(0)) return null;
  return `Avance à récupérer ${money(openMinor, currency)}`;
}

// -- « Passer une avance en perte » (plan §4.1.6, §4.3; founder Q5's default) -----------------------------------------

/** The sheet's effect sentence: what is recorded, what stops, that nothing is sent (never a remission of the debt). */
export function writeOffEffect(amountMinor: string, currency: string): string {
  return `Le cabinet enregistre une perte de ${money(amountMinor, currency)} (compte 6780). Collectoo ne réclame plus cette somme au client (ni reprise, ni demande de remboursement) ; rien ne lui est envoyé : ce n'est pas une remise de dette. Irréversible.`;
}

/** The command's refusal (« advance write-off refused: <code> », or not allowed), in French. */
export function writeOffRefusal(
  message: string | null | undefined,
  ctx: { open_minor: string; currency: string; in_flight_number: string | null },
): string {
  const code = (message ?? "").match(/advance write-off refused: (\w+)/)?.[1] ?? null;
  switch (code) {
    case "amount_exceeds_open":
      return `Le montant dépasse ce qui reste à récupérer (${money(ctx.open_minor, ctx.currency)}).`;
    case "open_changed":
      return "L'avance a changé depuis l'affichage : rechargez la page.";
    case "in_flight":
      return ctx.in_flight_number
        ? `Cette avance est reprise par le reversement ${ctx.in_flight_number} en cours : attendez son débit.`
        : "Cette avance est reprise par un reversement en cours : attendez son débit.";
    case "not_open":
      return "Cette avance est déjà récupérée.";
    case "evidence_required":
      return "Joignez la pièce justificative.";
    case "bad_amount":
      return "Montant invalide (en euros, deux décimales au plus).";
    case "reason_required":
      return "Indiquez le motif.";
    case "bad_request":
      return "La demande est incomplète : rechargez la page.";
    default:
      return /not allowed/.test(message ?? "")
        ? "Réservé aux administrateurs du cabinet (double authentification)."
        : "L'avance n'a pas pu être passée en perte. Réessayez ; si cela continue, prévenez le support.";
  }
}

const RUN_NUMBER = /^RV-\d{4}-\d{6}$/;

/** (review round 1, tests-ui-5) The sheet's refusal from the command's error: `in_flight` names the run that takes the
 *  advance back, which the command puts in the error's detail (a run approved after the page loaded). */
export function writeOffRefusalOf(
  error: { message?: string | null; details?: string | null },
  ctx: { open_minor: string; currency: string },
): string {
  const run = error.details && RUN_NUMBER.test(error.details) ? error.details : null;
  return writeOffRefusal(error.message, { ...ctx, in_flight_number: run });
}

// -- the client space (plan §4.3) --------------------------------------------------------------------------------------

export type ClientSpaceAdvances = {
  rows: { advance_id: string; currency: string; cause: AdvanceCause; created_on: string; born_on: string;
          open_minor: string; recovery: AdvanceRecovery; clause_ref: string | null }[];
  total: { currency: string; open_minor: string }[];
};

/** public.client_space_advances, or null when it is not its shape. */
export function parseClientSpaceAdvances(x: unknown): ClientSpaceAdvances | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  if (!Array.isArray(o.rows) || !Array.isArray(o.total)) return null;
  const rows: ClientSpaceAdvances["rows"] = [];
  for (const v of o.rows) {
    const r = v as Record<string, unknown>;
    if (!r || !isText(r.advance_id) || !isText(r.currency) || !isText(r.cause) || !CAUSES.has(r.cause)) return null;
    if (!isDay(r.created_on) || !isDay(r.born_on) || !isMinor(r.open_minor)) return null;
    if (!isText(r.recovery) || !RECOVERIES.has(r.recovery)) return null;
    if (!orNull(r.clause_ref, isText)) return null;
    rows.push({
      advance_id: r.advance_id,
      currency: r.currency,
      cause: r.cause as AdvanceCause,
      created_on: r.created_on,
      born_on: r.born_on,
      open_minor: r.open_minor,
      recovery: r.recovery as AdvanceRecovery,
      clause_ref: (r.clause_ref as string | null | undefined) ?? null,
    });
  }
  const total: ClientSpaceAdvances["total"] = [];
  for (const v of o.total) {
    const t = v as Record<string, unknown>;
    if (!t || !isText(t.currency) || !isMinor(t.open_minor)) return null;
    total.push({ currency: t.currency, open_minor: t.open_minor });
  }
  return { rows, total };
}

const CLIENT_ORIGIN: Record<AdvanceCause, string> = {
  remitted_reversal: "paiement repris après reversement",
  payout_overrun: "reversement au-delà de ce qui vous était dû",
  double_payout: "virement hors reversement",
};

/** What the client reads: the open total, and per advance its date (review round 2: its birth, the date the barred rule
 *  reads — never its recording, which can fall after the opening of a proceeding it predates), its origin, what is open
 *  and how it is recovered — the claw-back clause of its mandate, or a request (7c sends it: « pourra »); (review round
 *  1, M7B-MONEY-2) for one born before its collective proceeding opened, that it is not deducted (never « reprise »).
 *  (Review round 2) The total is said « à rembourser » only when no advance it holds predates the client's proceeding (a
 *  claim the client may not pay outside it): otherwise the heading is neutral and each line says its own fact. */
export function clientSpaceAdvances(s: ClientSpaceAdvances): { heading: string | null; lines: string[] } {
  if (s.rows.length === 0 || s.total.length === 0) return { heading: null, lines: [] };
  const owed = s.rows.every((r) => r.recovery !== "barred_proceeding");
  const heading = `Avances du cabinet${owed ? " à rembourser" : ""} : ${s.total.map((t) => money(t.open_minor, t.currency)).join(" · ")}`;
  const lines = s.rows.map((r) => {
    const how =
      r.recovery === "clawback"
        ? `reprise sur vos prochains reversements (${r.clause_ref ?? "clause de reprise"} du mandat)`
        : r.recovery === "barred_proceeding"
          ? "antérieure à l'ouverture de votre procédure collective, elle n'est pas déduite de vos reversements"
          : "une demande de remboursement pourra vous être adressée";
    return `Avance née le ${frenchDay(r.born_on)} (${CLIENT_ORIGIN[r.cause]}) : ${money(r.open_minor, r.currency)} — ${how}.`;
  });
  return { heading, lines };
}
