import type { ErrorCode } from "@/lib/boarding/forms";
import { money } from "@/lib/payments/statements";

/**
 * M2c-4 « Reversements » (design §17.1–§17.2): the words of the runs' states, blockers and failures, the deadline
 * chip, the amounts of a run's card. Every amount comes from the database as text (integer minor units): never a JS
 * number. No copy says « payé » before the bank's debit (M2c-6): a run is « validé », its transfer « ordonné ».
 */

type Tone = "neutral" | "busy" | "action" | "ok" | "error";

export type RunCard = {
  id: string;
  number: string;
  status: string;
  trigger: string;
  currency: string;
  client_id: string;
  client_name: string;
  version: number;
  job: string | null;
  known_at: string;
  prepared_at: string | null;
  item_count: number;
  line_count: number | null;
  gross_minor: string | null;
  net_minor: string | null;
  settlement_minor: string | null;
  invoice_ttc_minor: string | null;
  credit_ttc_minor: string | null;
  commission_taken_minor: string | null;
  refund_minor: string | null;
  advance_recovered_minor: string | null;
  earliest_latest_execution_date: string | null;
  earliest_deadline: string | null;
  unmeetable_count: number;
  requested_execution_date: string | null;
  blockers: string[];
  commission_blockers: string[];
  inputs_hash: string | null;
  last_failure: { code: string; detail?: string; at?: string; step?: string } | null;
  approved_at: string | null;
  booked_on: string | null;
  cancelled_at: string | null;
  cancel_reason: string | null;
  invoice_late: boolean;
  deadline_state: "ok" | "soon" | "critical" | "late" | null;
  payout: { iban_last4: string; holder_name: string; confirmed_at: string | null; new_iban: boolean } | null;
};

export const RUN_TABS: Record<string, { label: string }> = {
  "a-valider": { label: "À valider" },
  "en-cours": { label: "En cours" },
  termines: { label: "Terminés" },
};

export function runTab(value: string | string[] | undefined): string {
  const v = Array.isArray(value) ? value[0] : value;
  return v && v in RUN_TABS ? v : "a-valider";
}

type RunState = Pick<RunCard, "status" | "job" | "prepared_at"> & Partial<Pick<RunCard, "last_failure">>;

/**
 * A draft whose preparation failed (review M2c-4 tests-ui#3): no job in flight, never prepared, its last failure at
 * the prepare step (`private.remittance_prepare_failed`). Nothing retries it: ops « Actualiser » or « Abandonner ».
 */
export function prepareFailed(card: RunState): boolean {
  return card.status === "draft" && card.job === null && card.prepared_at === null && card.last_failure?.step === "prepare";
}

/** A run with work in flight (a job, or a draft not yet prepared): the pages refresh themselves meanwhile. */
export function runBusy(card: RunState): boolean {
  return card.job !== null || (card.status === "draft" && card.prepared_at === null && !prepareFailed(card));
}

export function runStatus(card: RunState): { label: string; tone: Tone } {
  if (card.status === "draft") {
    if (prepareFailed(card)) return { label: "Préparation échouée — actualisez", tone: "error" };
    if (card.job === "prepare" || card.prepared_at === null) return { label: "Préparation en cours", tone: "busy" };
    if (card.job === "approve") return { label: "Validation en cours", tone: "busy" };
    return { label: "Brouillon", tone: "action" };
  }
  const s: Record<string, { label: string; tone: Tone }> = {
    approved: { label: "Validé — virement ordonné", tone: "ok" },
    sent: { label: "Fichier transmis à la banque", tone: "ok" },
    booked: { label: "Comptabilisé", tone: "ok" },
    cancelled: { label: "Annulé", tone: "neutral" },
  };
  return s[card.status] ?? { label: card.status, tone: "neutral" };
}

export const TRIGGER_LABEL: Record<string, string> = {
  schedule: "Échéance du mandat",
  deadline: "Échéance R124-6",
  payout_returned: "Virement revenu",
  manual: "Préparé à la demande",
  // M2c-7d-2 ([check 2] gap 3, plan §6.2.11 (a) 8b): a run drafted to give back a set-off its payout's debit withheld
  settlement_withheld: "Compensation retenue à rendre",
};

const BLOCKER_LABEL: Record<string, string> = {
  client_funds_account_missing: "Aucun compte dédié actif dans cette devise",
  several_client_funds_accounts: "Plusieurs comptes dédiés actifs dans cette devise",
  payout_account_missing: "Aucun IBAN de reversement confirmé",
  payout_account_unconfirmed: "IBAN de reversement en attente de confirmation",
  payout_account_returned: "Dernier virement revenu : IBAN à remplacer ou reconfirmer",
  // M2c-7d-1 (plan §6.4; [critic] F16, L2, L10, L14): each block with its exit (the payee the events require,
  // confirmed by a second admin after them; a seizure until its release). Review round 1: an account « ouvert à son
  // nom » (C. civ. 427 al. 5), who makes it work depending on the measure (TUI-7); an old row to qualify first
  // (MONEY-LAW-1); (M2c-7d-2, plan §6.2.6, §6.2.9) a seizure bars the payouts and the set-off, whatever the run's net
  "client_status:liquidation":
    "Client en liquidation : compte du liquidateur à confirmer, avec le jugement qui le nomme (second administrateur)",
  "client_status:death":
    "Décès du client : confirmez le compte du notaire, ou celui que tous les héritiers désignent, avec la pièce (second administrateur)",
  "client_status:guardianship":
    "Client sous tutelle ou curatelle : confirmez un compte ouvert à son nom (art. 427 C. civ.), avec le jugement (second administrateur)",
  "client_status:curatorship":
    "Client sous tutelle ou curatelle : confirmez un compte ouvert à son nom (art. 427 C. civ.), avec le jugement (second administrateur)",
  "client_status:guardianship_to_qualify":
    "« Tutelle ou curatelle » enregistrée avant leur distinction : précisez-la avec le jugement (« Événements du client ») ; aucun compte ne lève ce blocage avant (règle du cabinet)",
  "client_status:mandate_ended": "Mandat terminé : confirmez à nouveau le compte du client (second administrateur)",
  "client_status:seizure":
    "Saisie entre les mains du cabinet : ni reversement ni compensation jusqu'à la mainlevée",
  negative_net: "Net négatif : les annulations dépassent les encaissements",
  servicer_identity_incomplete: "Identité de facturation du cabinet incomplète",
  client_identity_changed: "Le client n'est plus un professionnel établi en France métropolitaine",
  commission_terms_incomplete: "Conditions du mandat incomplètes (références des clauses)",
};

/** A blocker (payout) or a reason the commission stays pending, in French. */
export function blockerLabel(code: string): string {
  if (code.startsWith("commission_input_error")) return "La commission n'a pas pu être calculée (données à vérifier)";
  return BLOCKER_LABEL[code] ?? code;
}

const FAILURE_LABEL: Record<string, string> = {
  stale: "le brouillon a changé depuis l'affichage",
  vat_rate_changed: "le taux de TVA du jour n'est plus celui du brouillon : actualisez",
  commission_blocked: "la commission ne peut plus être facturée (identités)",
  payout_account_changed: "l'IBAN de reversement a changé depuis la préparation : actualisez",
  balance_changed: "solde modifié depuis l'aperçu : actualisez",
  history_changed: "l'historique des commissions a changé : actualisez",
  documents_changed: "les factures ouvertes ont changé : actualisez",
  items_changed: "les encaissements réservés ont changé : actualisez",
  negative_net: "net négatif",
  late_reason_required: "motif du retard requis",
  // the command's own refusals (review M2c-4 tests-ui#4, contract C1)
  unknown_run: "reversement introuvable",
  not_draft: "n'est plus un brouillon : rechargez",
  preparing: "préparation en cours : réessayez",
  approval_in_progress: "déjà en cours de validation",
  payout_blocked: "virement bloqué",
  busy: "traitement en cours sur ce reversement : réessayez",
  // the job's re-checks against what the draft was prepared with (money#1, money#2)
  vat_option_changed: "option TVA modifiée depuis la préparation : actualisez",
  client_status_changed: "situation du client modifiée depuis la préparation : actualisez",
  execution_date_passed: "la date d'exécution demandée est passée",
  execution_date_not_business_day: "la date d'exécution demandée n'est pas un jour ouvré",
  execution_date_after_cutoff: "exécution le jour même impossible après l'heure limite de la banque",
  approval_timeout: "la validation n'a pas abouti en 10 minutes",
  approval_failed: "la validation a échoué après plusieurs essais",
  prepare_failed: "la préparation a échoué",
  not_prepared: "le brouillon n'est pas préparé",
};

/** Why a run went back to draft (last_failure.code), as « Renvoyé en brouillon : … », or why the approval refused it. */
export function failureLabel(code: string): string {
  if (code.startsWith("payout_blocked:")) return `virement bloqué — ${blockerLabel(code.slice("payout_blocked:".length))}`;
  if (code.startsWith("data_error:")) return "les données ont été refusées par la base (voir le support)";
  return FAILURE_LABEL[code] ?? code;
}

/**
 * The note a draft's last failure shows (review M2c-4 tests-ui#3): a failed preparation says what to do; an approval
 * sent back says why (« Renvoyé en brouillon : … »).
 */
export function failureNote(failure: RunCard["last_failure"]): string | null {
  if (!failure) return null;
  if (failure.step === "prepare") return `Préparation échouée : ${failureLabel(failure.code)} — « Actualiser » la relance`;
  return `Renvoyé en brouillon : ${failureLabel(failure.code)}`;
}

/** The deadline chip (§17.1): green, orange from J-5 business days, red from J-1 and past. */
export function deadlineChip(date: string | null, state: RunCard["deadline_state"]): { label: string; tone: Tone } | null {
  if (!date) return null;
  const label = `Exécution au plus tard le ${frenchDate(date)}`;
  if (state === "late") return { label: `Délai dépassé : ${frenchDate(date)}`, tone: "error" };
  if (state === "critical") return { label, tone: "error" };
  if (state === "soon") return { label, tone: "action" };
  return { label, tone: "ok" };
}

export function frenchDate(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split("-");
  return `${d}/${m}/${y}`;
}

/** « IBAN confirmé il y a 3 j » (whole days since the confirmation, Paris calendar not needed for a badge). */
export function confirmedAgo(confirmedAt: string | null, now: Date = new Date()): string | null {
  if (!confirmedAt) return null;
  const days = Math.max(0, Math.floor((now.getTime() - new Date(confirmedAt).getTime()) / 86_400_000));
  return days === 0 ? "IBAN confirmé aujourd'hui" : `IBAN confirmé il y a ${days} j`;
}

/** Σ of minor-unit texts (BigInt), as text: the sticky « Valider n reversements · total ». */
export function sumMinor(values: (string | null | undefined)[]): string {
  return values.reduce((acc, v) => (v && /^-?\d+$/.test(v) ? acc + BigInt(v) : acc), BigInt(0)).toString();
}

/** What a run's line commission says (parts as stored by the engine): « 15 % sur 2 000,00 € ». */
export type Part = { rule_id: string; label_fr: string; tiers: [string, string][]; commission: string; held: string };

/** A rate as written (« 0.1500 », at most 4 decimals) in French percent, by string arithmetic (no float). */
export function percentText(rate: string): string {
  const m = /^(\d+)(?:\.(\d{1,4}))?$/.exec(rate);
  if (!m) return rate;
  const frac = (m[2] ?? "").padEnd(4, "0");
  const whole = (BigInt(m[1]) * BigInt(100) + BigInt(frac.slice(0, 2))).toString();
  const decimals = frac.slice(2).replace(/0+$/, "");
  return `${whole}${decimals ? `,${decimals}` : ""}\u00a0%`;
}

const COMMAND_ERRORS: [string, ErrorCode][] = [
  ["not allowed", "not_allowed"],
  ["run_pending", "run_pending"],
  ["nothing_pending", "nothing_pending"],
  ["version_changed", "run_version_changed"],
  ["not_draft", "run_not_draft"],
  ["approval_in_progress", "run_approval_in_progress"],
  ["already_sent", "run_already_sent"],
  // M2c-6a review (T1, money#2): a payout in a downloaded file is cancelled first (two people, the statement's
  // evidence), then its run
  ["payout_in_downloaded_file", "run_payout_in_downloaded_file"],
  // M2c-6a review, round 3 (E2): its payout, or one it re-issues, was debited already (a cancelled file executed late)
  ["transfer_already_debited", "run_transfer_already_debited"],
  ["no_statement_evidence", "transfer_no_statement_evidence"],
  // M2c-6a: a run whose file was downloaded is cancelled only with the attestation and a statement without its debit
  ["attestation_required", "transfer_attestation_required"],
  ["statement_not_imported", "transfer_statement_not_imported"],
  ["debit_seen", "transfer_debit_seen"],
  ["not_downloaded", "transfer_not_downloaded"],
  ["transfer_booked", "run_not_cancellable"],
  ["not_cancellable", "run_not_cancellable"],
  ["draft_use_discard", "run_not_cancellable"],
  ["a reason is required", "reason_required"],
  ["1 to 200 runs", "run_none_selected"],
  ["business calendar", "execution_date_invalid"],
  // a run, or the servicer's allocation work, locked by a job or another command (review M2c-4 tests-ui#5)
  ["could not obtain lock", "run_busy"],
  ["lock timeout", "run_busy"],
  // the commands' allocation lock waited too long (cancel, refresh, discard; review M2c-4 perf#4)
  ["allocation_busy", "run_busy"],
  // the documents' day turned at Paris midnight during the command (review M2c-4 nc#1): a new try works
  ["the day turned", "run_retry"],
];

/** Code for an error raised by a run command (never the database's text on the page). */
export function runErrorCode(message: string): ErrorCode {
  for (const [needle, code] of COMMAND_ERRORS) if (message.includes(needle)) return code;
  return "unknown";
}

export type ApprovalOutcome = { summary: string; queued: number; refused: number };

/** The approval's per-run outcome, as the result line says it (« 3 en validation ; RV-… refusé : … »), and its counts. */
export function approvalSummary(results: { number: string | null; status: string; reason: string | null }[]): ApprovalOutcome {
  const queued = results.filter((r) => r.status === "queued").length;
  const refused = results.filter((r) => r.status !== "queued");
  const parts = [`${queued} en validation`];
  for (const r of refused) parts.push(`${r.number ?? "?"} refusé : ${failureLabel(r.reason ?? "")}`);
  return { summary: parts.join(" ; "), queued, refused: refused.length };
}

/** The result line's colour: green when every run was queued, orange when some were refused, red when all were. */
export function summaryTone(o: Pick<ApprovalOutcome, "queued" | "refused">): "ok" | "action" | "error" {
  if (o.refused === 0) return "ok";
  return o.queued > 0 ? "action" : "error";
}

const MINOR = /^-?\d+$/;

/**
 * Whether the approval needs « Motif du retard » (design §9.5; review M2c-4 money#3), as the command decides it: a run
 * that transfers (N > 0) when the requested execution date is after its earliest latest execution date; a run that
 * transfers nothing (N = 0, settled at approval, today) when today (Europe/Paris) is after it.
 */
export function lateReasonRequired(
  runs: Pick<RunCard, "net_minor" | "earliest_latest_execution_date">[],
  date: string,
  today: string,
): boolean {
  return runs.some((r) => {
    const latest = r.earliest_latest_execution_date;
    if (latest === null || r.net_minor === null || !MINOR.test(r.net_minor)) return false;
    const net = BigInt(r.net_minor);
    if (net > BigInt(0)) return date > latest;
    return net === BigInt(0) && today > latest;
  });
}

/**
 * A credit note's refund owed to the client (review M2c-4 legal#5): paid with the run's payout, so « remboursé » only
 * once the run is booked (the bank's debit, M2c-6; or settled at approval when nothing is transferred).
 */
export function refundNote(card: Pick<RunCard, "status" | "refund_minor" | "currency">): string | null {
  if (!card.refund_minor || !MINOR.test(card.refund_minor) || BigInt(card.refund_minor) === BigInt(0)) return null;
  const amount = money(card.refund_minor, card.currency);
  return card.status === "booked" ? `avoir remboursé ${amount}` : `remboursement d'avoir inclus dans le virement : ${amount}`;
}

/**
 * M2c-6b-2c (plan §4.4, §7.4; critic CSO-6, CSO-9): what became of a run's payout, as `remittance_run_payout` returns
 * it (amounts text in minor units, dates ISO). The page formats; every amount and date is the database's.
 */
export type RunPayout = {
  transfers: {
    id: string;
    status: string;
    end_to_end_id?: string | null;
    amount_minor?: string | null;
    debited_on: string | null;
    returned_on: string | null;
    line_id: string | null;
    return_line_id?: string | null;
    repaid_by?: string | null;
    /** M2c-6b-3a-2 (F): a payout cancelled, booked as the run's payout (executed late by the bank) */
    late_predecessor?: boolean | null;
  }[];
  payout_account_blocked?: boolean | null;
  settled_on: string | null;
  settlement_minor: string;
  commission_minor: string;
  advances_recovered_minor: string;
  /** M2c-7b (plan §4.3): its open part (0 once reversed), whether its entry is reversed (a cover released), what was
   *  passed as a loss, how the rest is recovered (the mandate's claw-back clause, or a request) */
  advances: {
    cause: string;
    amount_minor: string;
    open_minor: string;
    created_on: string;
    reversed?: boolean | null;
    written_off_minor?: string | null;
    recovery?: string | null;
    clause_ref?: string | null;
  }[];
  unplanned: {
    line_id: string;
    kind: string;
    amount_minor: string;
    on: string;
    paid_minor: string;
    advance_minor: string;
    after_cancellation: boolean;
    returned?: boolean | null;
    /** (review M2c-6b-3a-2 round 2) closed by the return of another transfer of the run (its reference) */
    returned_by_end_to_end_id?: string | null;
  }[];
  draft_unplanned: { amount_minor: string; on: string; line_id: string; statement_on: string | null }[];
};

const positive = (v: string | null | undefined): v is string => !!v && MINOR.test(v) && BigInt(v) > BigInt(0);

/** M2c-7b (plan §4.3): what became of an advance recorded at this payout — released with its cause, recovered (in part
 *  passed as a loss), or how what is open is recovered. */
function advanceFate(a: RunPayout["advances"][number], currency: string): string {
  if (a.reversed) return "annulée (le virement hors reversement qui avait payé l'encaissement est revenu)";
  if (!positive(a.open_minor))
    return positive(a.written_off_minor)
      ? `soldée (dont ${money(a.written_off_minor, currency)} passés en perte)`
      : "récupérée";
  const rest = a.open_minor === a.amount_minor ? "" : `reste ${money(a.open_minor, currency)} `;
  if (a.recovery === "clawback")
    return `${rest}à reprendre sur les prochains reversements du client (clause de reprise, ${a.clause_ref ?? "clause"} du mandat)`;
  // (review round 1, M7B-MONEY-2; M2c-7d-2, [critic] L4) while the client's proceeding stands: no run takes it back,
  // no request asks for it
  if (a.recovery === "barred_proceeding")
    return `${rest}non reprise sur les reversements du client ni demandée (client en procédure collective : avance à déclarer)`;
  if (a.recovery === "request_no_mandate")
    return `${rest}à récupérer par une demande de remboursement (avance rattachée à aucun mandat unique)`;
  return `${rest}à récupérer par une demande de remboursement (pas de clause de reprise)`;
}

/** M2c-7a (plan §3.7): what each cause of an advance of the servicer says on the run page. */
const ADVANCE_CAUSE: Record<string, string> = {
  remitted_reversal: "encaissement de ce reversement annulé ou repris",
  payout_overrun: "reversement débité au-delà de ce qui restait dû",
  double_payout: "virement exécuté hors reversement",
};

/**
 * The run page's sentences on its payout (plan §7.4): the debit's date; the set-off with its date, each part from its
 * own field (« Commission » for the invoices set off, commission_minor; « Factures et avances » with each amount when it
 * also recovered advances, Da > 0; review 6b-2c pages-1: never D, which also nets a credit-note refund paid with the
 * transfer); the advances of the servicer at its debit, by cause (M2c-7a); a returned payout (its payout account said
 * blocked only while it is, and the run that paid it again once booked); each unplanned booking of its transfers (a
 * second execution, or one after the cancellation), and the return of one; for a draft, what it deducts of each
 * unplanned booking (CSO-6; review 6b-2c money-4: P, the net of that booking's own rows it holds, never A).
 * (M2c-7d-2) When its debit withheld part of the set-off (`withheld`), the plan's figures are not what was set off: the
 * set-off is then said by runWithheldNotes, from the ledger's settlements.
 */
export function runPayoutNotes(p: RunPayout, currency: string, withheld = false): string[] {
  const notes: string[] = [];
  for (const t of p.transfers) {
    // M2c-6b-3a-2 (T18): the late predecessor — its transfer cancelled, executed late by the bank; (review round 1,
    // pages-texts-1) under its own reference, the one the bank debited (the « Virement » section shows the re-issue)
    if (t.debited_on)
      notes.push(
        t.late_predecessor
          ? `Débité de notre compte le ${frenchDate(t.debited_on)}${
              t.end_to_end_id ? ` sous la référence ${t.end_to_end_id}` : ""
            } (virement annulé, exécuté en retard par la banque)`
          : `Débité de notre compte le ${frenchDate(t.debited_on)}`,
      );
  }
  // review 6b-2c (pages-1): each part of the set-off from its own field — D also nets a credit-note refund paid with the
  // transfer (refundNote says it), so the commission set off is commission_minor, never D
  if (p.settled_on && !withheld) {
    const on = frenchDate(p.settled_on);
    const commission = positive(p.commission_minor);
    const advances = positive(p.advances_recovered_minor);
    if (commission && advances)
      notes.push(
        `Factures et avances réglées par compensation le ${on} : commission ${money(p.commission_minor, currency)}, avances du cabinet ${money(p.advances_recovered_minor, currency)}`,
      );
    else if (commission) notes.push(`Commission réglée par compensation le ${on} : ${money(p.commission_minor, currency)}`);
    else if (advances)
      notes.push(`Avances du cabinet récupérées par compensation le ${on} : ${money(p.advances_recovered_minor, currency)}`);
  }
  // M2c-7a (plan §3.7 [critic] L19 (b), F5): each advance of this payout's chain, worded by its cause, with the date it
  // was recorded
  // M2c-7b (plan §4.3): and what became of it — never « déduite de ce reversement » (an advance recorded at this
  // payout's debit is recovered by the client's next runs, under the claw-back clause, or by a request)
  for (const a of p.advances) {
    const why = ADVANCE_CAUSE[a.cause];
    if (!why) continue;
    notes.push(
      `Avance du cabinet enregistrée le ${frenchDate(a.created_on)} (${why}) : ${money(a.amount_minor, currency)}, ${advanceFate(a, currency)}`,
    );
  }
  for (const t of p.transfers) {
    // M2c-6b-3a-2 (T18): also a late predecessor's return (its transfer stays cancelled)
    if (!(t.status === "returned" || (t.status === "cancelled" && t.late_predecessor)) || !t.returned_on || !t.amount_minor)
      continue;
    notes.push(
      `Virement revenu impayé le ${frenchDate(t.returned_on)} : ${money(t.amount_minor, currency)} de nouveau dus au client, proposés dans un prochain reversement${
        p.payout_account_blocked
          ? " ; son compte de reversement est bloqué jusqu'à son remplacement ou sa reconfirmation."
          : "."
      }`,
    );
    if (t.repaid_by) notes.push(`Reversé à nouveau par le reversement ${t.repaid_by}.`);
  }
  for (const u of p.unplanned) {
    const when = u.after_cancellation ? "après son annulation" : "une seconde fois";
    notes.push(
      `La banque a exécuté le virement de ce reversement ${when} le ${frenchDate(u.on)} (${money(u.amount_minor, currency)}) : comptabilisé hors reversement, avance du cabinet de ${money(u.advance_minor, currency)}.`,
    );
    // (review M2c-6b-3a-2 round 2) closed by the return of another transfer of the run: that copy came back, not this one
    if (u.returned && u.returned_by_end_to_end_id)
      notes.push(
        `Le virement ${u.returned_by_end_to_end_id} de ce reversement est revenu depuis : son retour solde ce virement hors reversement du ${frenchDate(u.on)} (le client n'a reçu ce reversement qu'une fois) ; il est comptabilisé.`,
      );
    else if (u.returned)
      notes.push(`Ce virement hors reversement du ${frenchDate(u.on)} est revenu depuis : son retour est comptabilisé.`);
  }
  for (const d of p.draft_unplanned) {
    notes.push(
      `Ce brouillon déduit ${money(d.amount_minor, currency)} déjà reçus par le client : virement exécuté hors reversement le ${frenchDate(d.on)}${
        d.statement_on ? ` (relevé du ${frenchDate(d.statement_on)})` : ""
      }.`,
    );
  }
  return notes;
}

/**
 * M2c-7d-2 (plan §6.2.11 (a)): what a run's payout debit withheld of its plan's set-off, as
 * `remittance_run_withheld` returns it (money staff of the servicer; amounts text in minor units, dates ISO) — the
 * client's status barred that set-off by the debit's date (the servicer's rule, its reason as the ledger records it),
 * so it was posted and reversed at once and the next run pays it back. (Review round 1, TUI-2) its parts are the frozen
 * plan's — the invoices and advances withheld, the credit note's refund not paid with them (W = their sum less that
 * refund when the whole plan is withheld); (MLAW-4, TUI-3) `given_back_by` names the run that paid W back once it is
 * booked (its payout not returned), `giving_back_by` the one approved or sent to pay it. (M2c-7d-3, carried item 4) The
 * run giving it back is followed through a returned payout to the run that pays it again; `returned_by` names the last
 * run whose payout came back on the way (null before 7d-3, or none).
 */
export type RunWithheld = {
  withheld_minor: string;
  commission_minor: string;
  advances_minor: string;
  refund_unpaid_minor: string;
  withheld_on: string;
  reason: string;
  set_off_commission_minor: string;
  set_off_advances_minor: string;
  given_back_by: string | null;
  giving_back_by: string | null;
  returned_by?: string | null;
};

/** The withheld set-off's read, or null (nothing withheld, or not the read's shape — never a guess). */
export function parseRunWithheld(x: unknown): RunWithheld | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  for (const k of [
    "withheld_minor",
    "commission_minor",
    "advances_minor",
    "refund_unpaid_minor",
    "set_off_commission_minor",
    "set_off_advances_minor",
  ])
    if (typeof o[k] !== "string" || !MINOR.test(o[k] as string)) return null;
  if (typeof o.withheld_on !== "string" || typeof o.reason !== "string") return null;
  for (const k of ["given_back_by", "giving_back_by", "returned_by"])
    if (o[k] !== null && o[k] !== undefined && typeof o[k] !== "string") return null;
  return {
    ...(o as unknown as RunWithheld),
    given_back_by: (o.given_back_by as string | null | undefined) ?? null,
    giving_back_by: (o.giving_back_by as string | null | undefined) ?? null,
    ...(o.returned_by !== undefined ? { returned_by: (o.returned_by as string | null) ?? null } : {}),
  };
}

/**
 * (Review M2c-7d-2 round 1, TUI-2) The refund a run actually paid with its payout: the plan's, less what its debit's
 * withholding left unpaid (the whole plan withheld: the credit note stays owed). What refundNote is given when a
 * withheld read exists.
 */
export function refundPaid(
  card: Pick<RunCard, "refund_minor">,
  withheld: Pick<RunWithheld, "refund_unpaid_minor"> | null,
): string | null {
  if (!card.refund_minor || !MINOR.test(card.refund_minor)) return card.refund_minor;
  if (!withheld) return card.refund_minor;
  return (BigInt(card.refund_minor) - BigInt(withheld.refund_unpaid_minor)).toString();
}

/**
 * The run page's sentences on a withheld set-off: what was withheld and why (the reason the ledger recorded, « règle
 * du cabinet » in it), whether a later run gave it back; then what the debit did set off, if anything.
 */
export function runWithheldNotes(w: RunWithheld, currency: string): string[] {
  const nonZero = (m: string) => MINOR.test(m) && BigInt(m) !== BigInt(0);
  const parts = [
    nonZero(w.commission_minor) ? `factures ${money(w.commission_minor, currency)}` : null,
    nonZero(w.advances_minor) ? `avances du cabinet ${money(w.advances_minor, currency)}` : null,
    // (review round 1, TUI-2) the credit note's refund the withheld plan did not pay: still owed to the client
    nonZero(w.refund_unpaid_minor)
      ? `moins le remboursement d'avoir non versé ${money(w.refund_unpaid_minor, currency)} qui reste dû au client`
      : null,
  ].filter((p): p is string => p !== null);
  const why = w.reason.replace(/^Compensation retenue : /, "");
  // (review round 1, MLAW-4, TUI-3) given back only once that run is booked; approved or sent, it is on its way;
  // (M2c-7d-3, carried item 4) through the run whose payout came back, when one did
  const returned = w.returned_by ?? null;
  const back = w.given_back_by
    ? `rendue au client par le reversement ${w.given_back_by}` +
      (returned ? ` (le virement du reversement ${returned} était revenu)` : "")
    : w.giving_back_by
      ? `à rendre au client par le reversement ${w.giving_back_by} (validé, virement en cours${
          returned ? ` ; le virement du reversement ${returned} était revenu` : ""
        })`
      : "à rendre au client par le prochain reversement" +
        (returned ? ` (le virement du reversement ${returned} qui la rendait est revenu)` : "");
  const notes = [
    `Compensation retenue au débit le ${frenchDate(w.withheld_on)} : ${money(w.withheld_minor, currency)}` +
      (parts.length > 0 ? ` (${parts.join(", ")})` : "") +
      ` — ${why} ; ${back}`,
  ];
  const setOff = [
    nonZero(w.set_off_commission_minor) ? `commission ${money(w.set_off_commission_minor, currency)}` : null,
    nonZero(w.set_off_advances_minor) ? `avances du cabinet ${money(w.set_off_advances_minor, currency)}` : null,
  ].filter((p): p is string => p !== null);
  if (setOff.length > 0) notes.push(`Réglé par compensation au débit : ${setOff.join(", ")}`);
  return notes;
}

/** The run page's read, or null when it is not the read's shape — never a guess. */
export function parseRunPayout(x: unknown): RunPayout | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  for (const k of ["transfers", "advances", "unplanned", "draft_unplanned"]) if (!Array.isArray(o[k])) return null;
  for (const k of ["settlement_minor", "commission_minor", "advances_recovered_minor"])
    if (typeof o[k] !== "string" || !MINOR.test(o[k] as string)) return null;
  return o as unknown as RunPayout;
}
