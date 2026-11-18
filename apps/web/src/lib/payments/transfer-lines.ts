// M2c-6b-2b (plan docs/design/m2c-6b-2-plan.md §3.10, §7.2): the ops command `public.book_transfer_line` and its
// preview refuse with `transfer line booking refused: <code>` (check_violation); this module turns a refusal, or the
// two SQLSTATEs the command gives a code of its own, into a code and its French label. Pure: the pages that book a
// line (« Débits et retours », 6b-2c) use it; raw database text never reaches the page.
import { errorText } from "../boarding/forms";
import { frenchDate } from "./bank-accounts";
import { maskedIban, money } from "./statements";

/** Each refusal of the command, the preview and the options, in French (plan §3.10). */
export const TRANSFER_LINE_REFUSAL: Record<string, string> = {
  bad_request: "La demande est incomplète ou mal formée : rouvrez la ligne et recommencez.",
  held_duplicate:
    "Cette ligne est retenue comme doublon possible : traitez-la d'abord dans « Doublons possibles ».",
  already_booked: "Cette ligne est déjà comptabilisée.",
  already_linked: "Cette ligne est déjà rattachée ou classée.",
  line_is_payment:
    "Cette ligne a été enregistrée comme le paiement d'un débiteur : elle ne peut pas être comptabilisée ici. Prévenez le support.",
  parts_do_not_add_up: "Les montants choisis ne font pas exactement le montant de la ligne.",
  not_a_transfer_line:
    "Cette ligne n'est pas un virement émis (c'est un remboursement, un prélèvement ou le retour d'un paiement) : elle ne se comptabilise pas ainsi.",
  // review LT-6: also a debit line named for an unplanned return that holds no unplanned booking of this transfer
  transfer_unknown:
    "Ce virement n'est pas un virement du cabinet sur ce compte, ou la ligne de débit indiquée ne l'a pas comptabilisé hors reversement.",
  // review LT-6: a transfer of the cabinet of another kind than the part (a quote-part named as a reversement)
  transfer_kind_differs:
    "Ce virement du cabinet n'est pas de ce type (reversement, quote-part du cabinet ou remboursement) : choisissez la comptabilisation qui lui correspond.",
  wrong_direction: "Ce virement ne peut pas être comptabilisé sur une ligne de ce sens (débit ou crédit).",
  not_its_line:
    "Cette ligne ne porte ni la référence de ce virement, ni celle de son lot dans son fichier, et rien ne permet de dire que c'est lui.",
  transfer_cancelled:
    "Ce virement est annulé : son débit se comptabilise comme « Virement hors reversement ».",
  already_debited:
    "Ce virement est déjà débité : un second débit se comptabilise comme « Virement hors reversement ».",
  not_handed_out:
    "Ce virement n'a jamais été remis à la banque (aucun fichier téléchargé) : ce débit ne peut pas encore être comptabilisé. Vérifiez dans la banque d'où vient cet ordre et prévenez le support.",
  transfer_differs: "Ce virement est d'un autre compte ou d'une autre devise que la ligne.",
  run_not_in_flight:
    "Le reversement de ce virement n'est plus en cours : ce débit ne peut pas encore être comptabilisé comme le sien. Prévenez le support.",
  amount_differs: "Le montant ne correspond pas à celui du virement.",
  line_ambiguous:
    "Plusieurs virements du cabinet (reversement, quote-part, remboursement, ou virement annulé que la banque a pu exécuter) ont ce montant vers ce compte : sans notre référence sur la ligne, impossible de savoir lequel la banque a exécuté. Demandez le détail à la banque.",
  batch_ambiguous:
    "Plusieurs combinaisons des virements de ce lot font le montant de la ligne : demandez à la banque le détail du lot.",
  // 6b-2d (suppression-e0-names-our-other-lot): a line with an end-to-end id that is not ours and the PmtInfId of one of
  // our lots, while a transfer of ours outside that lot has its amount to its account
  names_other_lot:
    "Cette ligne porte l'identifiant d'un autre lot de nos fichiers de virements que celui du virement du cabinet de ce montant vers ce compte : sans le détail de la banque, impossible de savoir si c'est son débit ou une nouvelle exécution d'un virement de cet autre lot. Elle ne peut pas être comptabilisée ici. Demandez le détail à la banque.",
  // critic CSO-3, critic2 CSO2-3: also an unsplit entry or a lot credit above the cap
  lot_too_large:
    "Ce lot ou cette écriture compte trop de virements pour être comptabilisé depuis cet écran : prévenez le support.",
  batch_mixed:
    "Ce lot contient des remboursements ou des virements de natures différentes : il ne peut pas être comptabilisé ici. Demandez le détail à la banque.",
  not_cancelled_nor_booked:
    "Ce virement n'est ni annulé, ni débité, ni revenu : comptabilisez la ligne comme « Débit d'un reversement » ; si ce virement n'a jamais été remis à la banque, prévenez le support.",
  // critic2 ML-4 (the page adds the run's number from the refusal's detail)
  run_still_live:
    "Ce virement a été annulé, mais son reversement est toujours en cours : ce débit est le paiement de ce reversement, pas un virement hors reversement. Il ne peut pas encore être comptabilisé ; ne faites pas annuler ce reversement et prévenez le support.",
  // critic2 ML-3
  debit_pending:
    "Un autre débit de ce virement (second débit, ou débit après annulation) figure sur un relevé sans être encore comptabilisé : comptabilisez-le d'abord ; ce retour sera alors celui du virement hors reversement, et rien ne sera reversé deux fois.",
  // critic2 ML-10
  fee_unexplained:
    "L'écart entre la ligne et le virement a le montant d'un virement du cabinet, et le relevé n'indique aucun frais : ce n'est sans doute pas des frais (virement débité deux fois, ou un autre virement dans la même écriture). Demandez le détail à la banque.",
  // critic F6 (the page adds the run's number from the refusal's detail)
  client_run_cancellable:
    "Les sommes que ce virement a payées sont dans un reversement de ce client validé mais pas encore remis à la banque : faites d'abord annuler ce reversement par un administrateur (ces sommes reviennent en attente et ce débit en sera déduit), puis recommencez.",
  client_unknown: "Ce client n'est pas un client du cabinet.",
  client_iban_mismatch: "Le compte crédité n'est pas un compte de reversement enregistré de ce client.",
  client_ambiguous:
    "Ce compte de reversement est enregistré pour plusieurs clients du cabinet : prévenez le support.",
  payout_in_flight_matches:
    "Un virement du cabinet en cours de ce montant vers ce compte (reversement, quote-part ou remboursement) peut être ce débit : comptabilisez-le comme son débit (« Débit d'un reversement »), ou rattachez-le au remboursement.",
  // critic F12
  cancelled_payout_matches:
    "Un virement annulé ou revenu de ce montant vers ce compte a pu être exécuté par la banque : comptabilisez ce débit comme son « Virement hors reversement ».",
  // critic F13
  payout_not_handed_out_matches:
    "Un reversement de ce client de ce montant n'a jamais été remis à la banque (pas encore dans un fichier téléchargé) : ce débit ne peut pas encore être comptabilisé. Vérifiez dans la banque d'où vient cet ordre et prévenez le support.",
  own_account_unknown: "Le compte crédité n'est pas l'un de nos comptes propres enregistrés.",
  sweep_in_flight_matches:
    "Une quote-part du cabinet en cours de ce montant peut être ce débit : comptabilisez-la comme son débit.",
  // M2c-6b-3a (K): rule 3b's (iv), raised only once cancellation after download is on
  cancelled_transfer_matches:
    "Ce débit peut être l'exécution tardive d'un remboursement ou d'une quote-part annulés après téléchargement : il ne peut pas être comptabilisé comme un autre virement. Demandez à la banque le détail de ce débit.",
  // critic L2, L15
  fee_not_allowed:
    "Des frais bancaires ne se comptabilisent ici que sur la ligne même d'un virement du cabinet (son débit, ou son retour signalé par la banque) : ailleurs, ils ne se distinguent pas de l'argent d'un tiers.",
  not_a_return: "Cette ligne n'est pas un crédit qui revient.",
  return_before_debit: "Le débit de ce virement n'est pas comptabilisé, ou il est daté d'après ce retour.",
  // critic F1
  unplanned_open:
    "Ce virement a aussi été exécuté hors reversement, et ce second virement n'est pas revenu : ce retour se comptabilise comme le sien (« Virement revenu », virement hors reversement), pour que rien ne soit reversé deux fois.",
  already_returned: "Ce virement est déjà revenu.",
  return_differs:
    "Ce retour ne correspond pas au virement (montant supérieur, virement sans débit comptabilisé, ou autre virement hors reversement à annuler d'abord).",
  advance_settled:
    "L'avance liée à ce virement a déjà été en partie récupérée : ce retour ne peut pas être comptabilisé ici. Prévenez le support.",
  // critic F8, critic2 ML-6
  unsplit_detail_missing:
    "Le relevé ne détaille pas assez cette écriture (un montant ou les frais de la banque manquent, ou la ligne a été importée avant que Collectoo garde ce détail) : elle ne peut pas être comptabilisée ici. Demandez le détail à la banque et prévenez le support.",
  // critic2 ML-5, CSO2-10
  unsplit_not_bookable:
    "Cette écriture contient autre chose que des virements du cabinet sur ce compte (le paiement d'un débiteur, un autre débit, un remboursement ou un approvisionnement du cabinet), ou deux fois le même virement : elle ne peut pas être comptabilisée ici. Demandez le détail à la banque et prévenez le support.",
  unsplit_parts_differ:
    "Les virements nommés ne sont pas exactement ceux que le relevé détaille dans cette écriture, à leurs montants.",
  split_changed:
    "La situation a changé depuis l'affichage (sommes en attente, brouillon, virements) : rouvrez la ligne pour voir la nouvelle répartition.",
  posting_failed:
    "La comptabilisation a été refusée par les contrôles du grand livre : rien n'est enregistré. Prévenez le support.",
  // the two SQLSTATEs (§3.10): the lock wait, re-raised with the step it waited at (critic2 CSO2-6), and the statement
  // timeout (critic CSO-3)
  busy: "Cette ligne ou un virement qu'elle concerne est en cours de traitement : réessayez dans un instant.",
  allocation_busy:
    "Une imputation ou une validation de reversements est en cours pour ce cabinet : réessayez dans quelques secondes.",
  timeout:
    "La comptabilisation a pris trop de temps et n'a rien enregistré : réessayez ; si cela se répète, prévenez le support.",
};

const REFUSED = /transfer line booking refused: ([a-z_]+)/;

/** The code of an error the command, the preview or the options raised (never the database's text on the page). */
export function transferLineErrorCode(error: { code?: string | null; message?: string | null }): string {
  const message = error.message ?? "";
  const refused = REFUSED.exec(message);
  if (refused) return refused[1];
  // review CSR-1: a deadlock or a serialisation failure aborts the call and records nothing — retried like a lock wait
  if (
    error.code === "55P03" ||
    error.code === "40P01" ||
    error.code === "40001" ||
    message.includes("lock timeout") ||
    message.includes("could not obtain lock") ||
    message.includes("deadlock detected")
  )
    return "busy";
  if (error.code === "57014" || message.includes("statement timeout")) return "timeout";
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("a reason is required")) return "reason_required";
  return "unknown";
}

/** The French text of a code `transferLineErrorCode` returned; « not allowed » and the motif keep their labels. */
export function transferLineErrorText(code: string): string {
  if (code === "not_allowed" || code === "reason_required") return errorText(code);
  return TRANSFER_LINE_REFUSAL[code] ?? errorText("unknown");
}

// ---------------------------------------------------------------------------------------------------------------------
// M2c-6b-2c (plan §3.11, §7.3): the sheets of « Débits et retours » that book our transfer lines. The options read
// (public.transfer_line_options) and the preview (public.transfer_line_preview) are parsed here; every amount, date and
// P comes from them — the sentences below only word what SQL returned (no amount, date or legal mention computed).
// ---------------------------------------------------------------------------------------------------------------------

/** One part as private.transfer_line_parts_json returns it (amounts as text). */
export type TransferLinePart = {
  n?: number;
  kind: string;
  transfer_id: string | null;
  client_id: string | null;
  returns_line_id: string | null;
  amount_minor: string;
  paid_minor: string;
  advance_minor: string;
  p_bound: string | null;
  late: boolean;
  end_to_end_id: string | null;
  run_id: string | null;
  run_number: string | null;
  status: string | null;
  client_name: string | null;
  /** a payout's run set-off (D) */
  settlement_minor?: string | null;
  /** a payout's run: the earliest latest execution date of its positive live lines */
  latest_execution_date?: string | null;
  /** an unplanned sweep: the servicer's share on the dedicated account once it is booked */
  share_after_minor?: string | null;
  /** a return: the last four characters of the payout account it marks returned, and whether it blocks it */
  payout_iban_end?: string | null;
  blocks_account?: boolean;
  /** an unplanned return: the date of the line it reverses */
  returns_on?: string | null;
};

export type TransferLinePreview = {
  ok: boolean;
  why: string | null;
  detail: string | null;
  parts: TransferLinePart[];
  drafts: { run_id: string; number: string }[];
  supersedes_file: { file_id: string; number: string } | null;
  expected_text: string | null;
};

export type TransferLineProposal = {
  action: string;
  /** the parts as the command takes them (sent back as they are) */
  request: unknown[];
  parts: TransferLinePart[];
  preview: TransferLinePreview;
};

export type TransferLineMember = {
  transfer_id: string;
  kind?: string;
  status?: string;
  amount_minor?: string;
  run_number?: string | null;
  client_name?: string | null;
  end_to_end_id?: string | null;
  in_proposal: boolean;
};

export type TransferLineOptions = {
  class: string;
  kind: string;
  direction: string;
  amount_minor: string;
  booking_date: string | null;
  unsplit_ours: number | null;
  charges_minor: string | null;
  counterparty_iban_end: string | null;
  proposals: TransferLineProposal[];
  members: TransferLineMember[] | null;
  member_count: number | null;
  refusal: string | null;
  refusal_detail: string | null;
  pending_line_id: string | null;
  /** review 6b-2c (pages-5): the pending debit is held as a suspected duplicate (« Doublons possibles ») */
  pending_held: boolean;
};

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
function text(v: unknown): string | null {
  return typeof v === "string" ? v : typeof v === "number" ? String(v) : null;
}
function parsePart(raw: unknown): TransferLinePart | null {
  if (!isObject(raw) || typeof raw.kind !== "string") return null;
  return {
    n: typeof raw.n === "number" ? raw.n : undefined,
    kind: raw.kind,
    transfer_id: text(raw.transfer_id),
    client_id: text(raw.client_id),
    returns_line_id: text(raw.returns_line_id),
    amount_minor: text(raw.amount_minor) ?? "0",
    paid_minor: text(raw.paid_minor) ?? "0",
    advance_minor: text(raw.advance_minor) ?? "0",
    p_bound: text(raw.p_bound),
    late: raw.late === true,
    end_to_end_id: text(raw.end_to_end_id),
    run_id: text(raw.run_id),
    run_number: text(raw.run_number),
    status: text(raw.status),
    client_name: text(raw.client_name),
    settlement_minor: text(raw.settlement_minor),
    latest_execution_date: text(raw.latest_execution_date),
    share_after_minor: text(raw.share_after_minor),
    payout_iban_end: text(raw.payout_iban_end),
    blocks_account: raw.blocks_account === true,
    returns_on: text(raw.returns_on),
  };
}
function parseParts(raw: unknown): TransferLinePart[] {
  return Array.isArray(raw) ? raw.map(parsePart).filter((p): p is TransferLinePart => p !== null) : [];
}

/** The preview of public.transfer_line_preview (or of a proposal), or null when it is not that shape. */
export function parseTransferLinePreview(raw: unknown): TransferLinePreview | null {
  if (!isObject(raw) || typeof raw.ok !== "boolean" || !Array.isArray(raw.parts) || !Array.isArray(raw.drafts))
    return null;
  const file = isObject(raw.supersedes_file) ? raw.supersedes_file : null;
  return {
    ok: raw.ok,
    why: text(raw.why),
    detail: text(raw.detail),
    parts: parseParts(raw.parts),
    drafts: raw.drafts.filter(isObject).map((d) => ({ run_id: text(d.run_id) ?? "", number: text(d.number) ?? "" })),
    supersedes_file:
      file && text(file.number) ? { file_id: text(file.file_id) ?? "", number: text(file.number) ?? "" } : null,
    expected_text: text(raw.expected_text),
  };
}

/** The options of public.transfer_line_options, or null when it is not that shape (another servicer's line: null). */
export function parseTransferLineOptions(raw: unknown): TransferLineOptions | null {
  if (!isObject(raw) || typeof raw.class !== "string" || !Array.isArray(raw.proposals)) return null;
  const proposals: TransferLineProposal[] = [];
  for (const p of raw.proposals) {
    if (!isObject(p) || typeof p.action !== "string" || !Array.isArray(p.request)) continue;
    const preview = parseTransferLinePreview(p.preview);
    if (!preview) continue;
    proposals.push({ action: p.action, request: p.request, parts: parseParts(p.parts), preview });
  }
  return {
    class: raw.class,
    kind: text(raw.kind) ?? "",
    direction: text(raw.direction) ?? "",
    amount_minor: text(raw.amount_minor) ?? "0",
    booking_date: text(raw.booking_date),
    unsplit_ours: typeof raw.unsplit_ours === "number" ? raw.unsplit_ours : null,
    charges_minor: text(raw.charges_minor),
    counterparty_iban_end: text(raw.counterparty_iban_end),
    proposals,
    members: Array.isArray(raw.members)
      ? raw.members.filter(isObject).map((m) => ({
          transfer_id: text(m.transfer_id) ?? "",
          kind: text(m.kind) ?? undefined,
          status: text(m.status) ?? undefined,
          amount_minor: text(m.amount_minor) ?? undefined,
          run_number: text(m.run_number),
          client_name: text(m.client_name),
          end_to_end_id: text(m.end_to_end_id),
          in_proposal: m.in_proposal === true,
        }))
      : null,
    member_count: typeof raw.member_count === "number" ? raw.member_count : null,
    refusal: text(raw.refusal),
    refusal_detail: text(raw.refusal_detail),
    pending_line_id: text(raw.pending_line_id),
    pending_held: raw.pending_held === true,
  };
}

/**
 * Review 6b-2c (pages-5): where the debit a `debit_pending` refusal names waits, and the link to it — in « Doublons
 * possibles » when it is held as a suspected duplicate (the return is taken up once it is decided a duplicate: the
 * debit job runs again, review M2c-6b-2a M1), else in « À classer ». Null when the options name no pending line.
 */
export function pendingLineNote(
  o: Pick<TransferLineOptions, "pending_line_id" | "pending_held">,
): { text: string | null; href: string; label: string } | null {
  if (!o.pending_line_id) return null;
  return o.pending_held
    ? {
        text: "Ce débit attend dans « Doublons possibles » : décidez-le d'abord ; reconnu comme doublon, il ne compte plus et ce retour est repris automatiquement.",
        href: `/backoffice/encaissements/debits?onglet=doublons#ligne-${o.pending_line_id}`,
        label: "Voir la ligne dans « Doublons possibles »",
      }
    : {
        text: null,
        href: `/backoffice/encaissements/debits?onglet=a-classer#ligne-${o.pending_line_id}`,
        label: "Voir la ligne du débit",
      };
}

/** Each action's sheet: its button on the line, the sheet's title, its intro, the booking button (plan §7.3). */
export const TRANSFER_LINE_ACTION: Record<string, { label: string; button: string; intro: string }> = {
  payout: {
    label: "Débit d'un reversement",
    button: "Comptabiliser le débit",
    intro:
      "La banque a débité ce virement du cabinet : la ligne est comptabilisée comme son débit, comme l'import le fait quand la ligne porte sa référence.",
  },
  // review 6b-2c (pages-4): a `payout` proposal whose part is our sweep (the command's action stays `payout`)
  sweep: {
    label: "Débit de la quote-part du cabinet",
    button: "Comptabiliser le débit",
    intro:
      "La banque a débité ce virement du cabinet : la ligne est comptabilisée comme son débit, comme l'import le fait quand la ligne porte sa référence.",
  },
  lot: {
    label: "Débit d'un lot de reversements",
    button: "Comptabiliser le débit",
    intro:
      "La banque a débité ces virements du cabinet en une seule ligne : elle est comptabilisée comme leur débit, comme l'import le fait quand la ligne porte la référence de son lot et que ses virements en font le montant.",
  },
  unplanned_payout: {
    label: "Virement hors reversement",
    button: "Comptabiliser le virement",
    intro: "",
  },
  unplanned_sweep: {
    label: "Virement au compte propre",
    button: "Comptabiliser le virement",
    intro: "",
  },
  returned: {
    label: "Virement revenu",
    button: "Comptabiliser le retour",
    intro:
      "La banque du bénéficiaire a renvoyé ce virement du cabinet : il est comptabilisé comme revenu, comme l'import le fait quand la banque le signale comme un retour.",
  },
  detail: {
    label: "Comptabiliser d'après le détail du relevé",
    button: "Comptabiliser",
    intro:
      // review M2c-6b-2d round 1 (pages-e2e-1): the only detail of ours with the charges the statement records (S08)
      "La banque a regroupé plusieurs opérations dans cette écriture. Le relevé détaille nos virements qu'elle contient : s'ils en font exactement le montant, ou si l'écriture ne détaille que l'un de nos virements et que les frais indiqués par le relevé font la différence, ils sont comptabilisés chacun (débit ou retour), avec ces frais.",
  },
};

/**
 * The proposal's button: an entry kept unsplit (class U) is booked from the statement's own detail, whatever its parts;
 * review 6b-2c (pages-4): a `payout` proposal debiting our sweep is « Débit de la quote-part du cabinet », as « Traités »
 * names its booking (DECISION_LABEL.sweep).
 */
export function transferLineActionLabel(action: string, lineClass: string, parts: { kind: string }[] = []): string {
  if (lineClass === "U") return TRANSFER_LINE_ACTION.detail.label;
  const ours = parts.filter((p) => p.kind !== "fee");
  if (action === "payout" && ours.length > 0 && ours.every((p) => p.kind === "sweep"))
    return TRANSFER_LINE_ACTION.sweep.label;
  return TRANSFER_LINE_ACTION[action]?.label ?? TRANSFER_LINE_ACTION.payout.label;
}

/** The booking button of a proposal (an unsplit entry's: « Comptabiliser »). */
export function transferLineButton(action: string, lineClass: string): string {
  if (lineClass === "U") return TRANSFER_LINE_ACTION.detail.button;
  return TRANSFER_LINE_ACTION[action]?.button ?? TRANSFER_LINE_ACTION.payout.button;
}

/** « Comptabiliser… » on a row of the queue, from its cheap bookable_as (critic CSO-4: the options are read on open). */
export function offersTransferLineBooking(row: { bookable_as?: string | null }): boolean {
  return row.bookable_as === "e" || row.bookable_as === "b" || row.bookable_as === "n" || row.bookable_as === "u";
}

/** A refusal's label, with the run its detail names when the label says « ce reversement » (critic F6, critic2 ML-4). */
export function transferLineRefusalText(code: string, detail: string | null): string {
  const base = transferLineErrorText(code);
  if ((code === "client_run_cancellable" || code === "run_still_live") && detail)
    return `${base} (reversement ${detail})`;
  return base;
}

/**
 * What this line does of a lot's member (plan §7.3 « Dans cette ligne »). Review 6b-2c (pages-3): by the line's
 * direction — a lot credit returns its members — and only when the options propose a booking (`decided`): a lot no
 * single subset makes (or refused otherwise) says which members it holds only once the bank confirms it.
 */
export function memberInLine(
  member: { transfer_id: string; in_proposal: boolean },
  parts: { kind: string; transfer_id: string | null }[],
  line: { direction: string; decided: boolean },
): string {
  if (!line.decided) return "à confirmer par la banque";
  if (line.direction === "credit") return member.in_proposal ? "revient par cette ligne" : "ne revient pas par cette ligne";
  if (!member.in_proposal) return "non débité par cette ligne";
  const part = parts.find((p) => p.transfer_id === member.transfer_id);
  return part?.kind === "unplanned_payout" || part?.kind === "unplanned_sweep"
    ? "second débit, hors reversement"
    : "débit";
}

/** « … et N autres » when the options listed only the first members (at most 50, critic2 CSO2-3). */
export function membersMore(o: { members: unknown[] | null; member_count: number | null }): string | null {
  if (!o.members || o.member_count === null || o.member_count <= o.members.length) return null;
  return `… et ${o.member_count - o.members.length} autres`;
}

const STATED_CHARGES = "frais indiqués par le relevé";
const UNSTATED_CHARGES =
  "Le relevé n'indique pas de frais pour cette ligne : l'écart n'est pas justifié par le relevé. Vérifiez dans la banque avant de comptabiliser.";
const NOT_YET_RECOVERED = "à récupérer selon son mandat — ce recouvrement n'est pas encore géré dans Collectoo";
const REFERENCE_LESS =
  "Cette ligne ne porte pas notre référence : seul ce virement du cabinet (en cours, ou annulé que la banque a pu exécuter) a ce montant vers ce compte. Vérifiez dans la banque avant de comptabiliser.";

// review 6b-2c (T1, pages-2): an IBAN as the rest of the page masks it (maskedIban: « IBAN …1234 »), from the last four
// characters SQL returns — never a country code or check digits it did not give
function blockSentence(p: TransferLinePart): string {
  return p.blocks_account && p.payout_iban_end
    ? ` ; son compte de reversement (${maskedIban(p.payout_iban_end)}) est bloqué jusqu'à son remplacement ou sa reconfirmation`
    : "";
}

/** One part's sentences (plan §7.3; critic L3, L13; critic2 ML-9, ML-11). */
function partEffects(
  options: TransferLineOptions,
  p: TransferLinePart,
  m: (minor: string | null | undefined) => string,
): string[] {
  const client = p.client_name ?? "le client";
  const lineDate = frenchDate(options.booking_date);
  const referenceLess = ["N", "O", "E0"].includes(options.class);
  switch (p.kind) {
    case "payout": {
      const setoff =
        p.settlement_minor && p.settlement_minor !== "0"
          ? ` ; ses factures sont réglées par compensation (${m(p.settlement_minor)})`
          : "";
      const out = [
        // review M2c-6b-2d round 1 (pages-e2e-4): each status by the label its page shows (transfers.ts, runs.ts)
        `${p.run_number ?? "Le reversement"} (${client}) : ${m(p.amount_minor)} débités le ${lineDate}${setoff} ; son virement passe à « Débité » et le reversement à « Comptabilisé ».`,
      ];
      if (p.late && p.latest_execution_date)
        out.push(
          `Ce débit est postérieur à la date limite d'exécution du ${frenchDate(p.latest_execution_date)} : le dépassement du délai est enregistré.`,
        );
      return out;
    }
    case "sweep":
      return [`Quote-part du cabinet de ${m(p.amount_minor)} débitée le ${lineDate} vers notre compte propre.`];
    case "unplanned_payout": {
      const out = [
        `La banque a exécuté un virement vers ${client} hors de tout reversement en cours (virement annulé exécuté quand même, second débit d'un virement, ou virement saisi à la banque). Il est comptabilisé tel quel : le client a reçu cet argent.`,
      ];
      // review 6b-2c (round 1): the sums this payout is netted from, by what became of its transfer — a cancelled run's
      // (its run cancelled), or those its own return put back (a returned payout executed again: its run is not
      // cancelled)
      const run = p.run_number ? `du reversement ${p.run_number}` : "d'un reversement";
      const source =
        p.status === "returned"
          ? `(sommes ${run} remises à reverser par le retour de son virement)`
          : p.status === "cancelled"
            ? `(sommes ${run} annulé, encore à reverser)`
            : `(sommes ${run} annulé — ou du virement revenu — encore à reverser)`;
      const paid = BigInt(p.paid_minor || "0");
      const advance = BigInt(p.advance_minor || "0");
      if (paid === BigInt(0))
        out.push(
          `Rien n'est déduit du prochain reversement de ${client} ; avance du cabinet de ${m(p.advance_minor)} : ce virement n'est rattaché à aucune somme en attente de ce client, ${NOT_YET_RECOVERED}.`,
        );
      else if (advance === BigInt(0))
        out.push(
          `${m(p.paid_minor)} déjà reçus par ${client} seront déduits de son prochain reversement ${source} ; avance du cabinet : ${m("0")}.`,
        );
      else {
        const why =
          p.p_bound === "items"
            ? " (le reste dépasse ce qui reste dû au client sur ces sommes)"
            : p.p_bound === "queue"
              ? " (les sommes en attente du client ne permettent pas d'en déduire davantage)"
              : "";
        out.push(
          `${m(p.paid_minor)} déjà reçus par ${client} seront déduits de son prochain reversement ${source} ; avance du cabinet de ${m(p.advance_minor)} pour le reste${why}, ${NOT_YET_RECOVERED}.`,
        );
      }
      return out;
    }
    case "unplanned_sweep": {
      const iban = options.counterparty_iban_end ? ` (${maskedIban(options.counterparty_iban_end)})` : "";
      const out = [
        `Virement du compte dédié vers notre compte propre${iban} sans ordre de Collectoo (ou exécuté après son annulation) : comptabilisé comme quote-part du cabinet virée au compte propre.`,
        `La quote-part du cabinet en attente sur le compte dédié baisse de ${m(p.amount_minor)}.`,
      ];
      if (p.share_after_minor && BigInt(p.share_after_minor) < BigInt(0))
        out.push(
          `Elle devient négative (${m(p.share_after_minor)}) : le cabinet doit cette somme au compte dédié ; demandez un approvisionnement depuis le compte propre.`,
        );
      return out;
    }
    case "payout_returned":
      return [
        `${p.run_number ?? "Le reversement"} : ${m(p.amount_minor)} de nouveau dus à ${client}, proposés dans un prochain reversement avec la date limite de leurs encaissements${blockSentence(p)}.`,
      ];
    case "sweep_returned":
      return [
        `La quote-part de ${m(p.amount_minor)} revient sur le compte dédié : elle sera virée de nouveau au compte propre.`,
      ];
    case "unplanned_payout_returned": {
      const on = p.returns_on ? frenchDate(p.returns_on) : "";
      const out: string[] = [];
      if (referenceLess)
        out.push(
          `La banque signale ce crédit comme un retour, sans notre référence, depuis le compte vers lequel le virement hors reversement du ${on} (${m(p.amount_minor)}) est parti : il est comptabilisé comme son retour. Vérifiez dans la banque avant de comptabiliser.`,
        );
      if (BigInt(p.paid_minor || "0") === BigInt(0))
        out.push(
          `Le virement hors reversement du ${on} (${m(p.amount_minor)}) revient : l'avance du cabinet de ${m(p.advance_minor)} est annulée ; rien n'est de nouveau dû à ${client}${blockSentence(p)}.`,
        );
      else
        out.push(
          `Le virement hors reversement du ${on} (${m(p.amount_minor)}) revient : l'avance du cabinet de ${m(p.advance_minor)} est annulée et ${m(p.paid_minor)} sont de nouveau dus à ${client}${blockSentence(p)}.`,
        );
      return out;
    }
    case "unplanned_sweep_returned":
      return [
        `Le virement au compte propre de ${m(p.amount_minor)} revient sur le compte dédié : la quote-part du cabinet en attente sur le compte dédié remonte d'autant.`,
      ];
    default:
      return [];
  }
}

/** The sentences a proposal's sheet shows, worded from its preview (plan §7.3; critic L3, L13; critic2 ML-9 to ML-11,
 * CSO2-4: the file replaced only when the preview says so). */
export function transferLineEffects(
  options: TransferLineOptions,
  proposal: TransferLineProposal,
  currency: string,
): string[] {
  const m = (minor: string | null | undefined) => money(minor ?? "0", currency);
  const preview = proposal.preview;
  const parts = preview.parts.length > 0 ? preview.parts : proposal.parts;
  const out: string[] = [];
  const intro = options.class === "U" ? TRANSFER_LINE_ACTION.detail.intro : TRANSFER_LINE_ACTION[proposal.action]?.intro;
  if (intro) out.push(intro);
  for (const p of parts) out.push(...partEffects(options, p, m));
  const fee = parts.find((p) => p.kind === "fee");
  if (fee) {
    const stated = options.charges_minor !== null && options.charges_minor === fee.amount_minor;
    const charges = stated ? ` (${STATED_CHARGES})` : "";
    out.push(
      options.direction === "credit"
        ? `Frais de la banque déduits du retour : ${m(fee.amount_minor)}, à la charge du cabinet${charges}.`
        : `Frais bancaires de ${m(fee.amount_minor)} prélevés sur la même ligne, à la charge du cabinet${charges}.`,
    );
    if (!stated) out.push(UNSTATED_CHARGES);
  }
  if (["N", "O", "E0"].includes(options.class) && options.direction === "debit" && proposal.action === "payout")
    out.push(REFERENCE_LESS);
  for (const d of preview.drafts)
    out.push(`Le brouillon ${d.number} sera recalculé ; sa validation en cours, s'il y en a une, est interrompue.`);
  if (preview.supersedes_file)
    out.push(
      `Le fichier ${preview.supersedes_file.number} pas encore téléchargé sera remplacé à son téléchargement : sa quote-part dépasserait alors ce qui revient au cabinet.`,
    );
  return out;
}
