import { formatMoneyFr } from "@/lib/money";

/**
 * M2b-2: bank statements on the back-office (« Relevés »). Pure helpers, unit-tested. Amounts arrive
 * as text (integer minor units) and become BigInt: they never pass through a JS number.
 */

export type Tone = "neutral" | "busy" | "action" | "ok" | "error";

export const STATEMENT_STATUS: Record<string, { label: string; tone: Tone }> = {
  awaiting_upload: { label: "En attente du fichier", tone: "neutral" },
  uploaded: { label: "Import en cours", tone: "busy" },
  imported: { label: "Importé", tone: "ok" },
  rejected: { label: "Refusé", tone: "error" },
  failed: { label: "Échec", tone: "error" },
};

export function statementStatus(status: string): { label: string; tone: Tone } {
  return STATEMENT_STATUS[status] ?? { label: status, tone: "neutral" };
}

/** Money from integer minor units given as text ("123450" -> "1 234,50 €"). */
export function money(minor: string | null | undefined, currency: string): string {
  if (minor === null || minor === undefined || !/^-?\d+$/.test(minor)) return "–";
  return formatMoneyFr({ minor: BigInt(minor), currency });
}

/** A line's amount with its sign: credits +, debits −. */
export function signedMoney(direction: string, minor: string, currency: string): string {
  const text = money(minor, currency);
  return direction === "debit" ? `− ${text}` : `+ ${text}`;
}

/** What a statement line is, and where it stands: payments are booked at import; since M2b-6 a debit linked to a
 * payment (its return) or to our refund is booked too, a line ops explained or a confirmed duplicate stays out of the
 * books, fees and other debits are explained gaps (founder #20); the rest waits to be classified. */
export function lineState(line: {
  kind: string;
  direction: string;
  has_payment: boolean;
  link?: string | null; // bank_debit_link.kind
  duplicate?: string | null; // bank_duplicate_resolution.decision
}): {
  kind: string;
  state: string;
  tone: Tone;
} {
  const kind =
    line.kind === "batch_unsplit" && line.direction === "debit"
      ? "Débit groupé non ventilé"
      : (LINE_KIND[line.kind] ?? line.kind);
  if (line.has_payment) return { kind, state: "Comptabilisé · à affecter", tone: "ok" };
  if (line.link === "return") return { kind, state: "Comptabilisé · retour du paiement", tone: "ok" };
  if (line.link === "refund") return { kind, state: "Comptabilisé · remboursement exécuté", tone: "ok" };
  if (line.link === "refund_returned") return { kind, state: "Comptabilisé · remboursement revenu", tone: "ok" };
  if (line.link === "explained") return { kind, state: "Expliqué · non comptabilisé", tone: "neutral" };
  if (line.duplicate === "duplicate") return { kind, state: "Doublon confirmé · non comptabilisé", tone: "neutral" };
  if (line.kind === "suspected_duplicate" && line.duplicate !== "released")
    return { kind, state: "Retenu : doublon possible", tone: "action" };
  if (line.kind === "other_debit") return { kind, state: "Non comptabilisé · écart expliqué (frais)", tone: "neutral" };
  return { kind, state: "Non comptabilisé · à classer", tone: "action" };
}

const LINE_KIND: Record<string, string> = {
  debtor_credit: "Encaissement",
  batch_unsplit: "Remise groupée non ventilée",
  return: "Retour ou rejet",
  refund_out: "Remboursement émis",
  other_debit: "Débit (frais, autre)",
  suspected_duplicate: "Doublon possible",
  psp_payout: "Versement du prestataire de paiement",
};

/** Lines of these kinds (and of this direction, when given). */
type LineGroup = { direction?: "credit" | "debit"; kinds: string[] };

/**
 * Filters of a statement's lines. « Encaissements » are exactly the lines booked as payments (credits a
 * debtor paid, an unsplit batch credit); everything else not held is « à classer », an unsplit debit
 * batch included: what the bank check counts as not booked.
 */
export const LINE_FILTERS: Record<string, { label: string; groups: LineGroup[] | null }> = {
  toutes: { label: "Toutes", groups: null },
  encaissements: { label: "Encaissements", groups: [{ direction: "credit", kinds: ["debtor_credit", "batch_unsplit"] }] },
  "a-classer": {
    label: "À classer",
    groups: [{ kinds: ["return", "refund_out", "other_debit", "psp_payout"] }, { direction: "debit", kinds: ["batch_unsplit"] }],
  },
  doublons: { label: "Doublons possibles", groups: [{ kinds: ["suspected_duplicate"] }] },
};

/** Whether a line belongs to a filter (the rule `lineFilterOr` gives PostgREST). */
export function lineInFilter(key: string, line: { kind: string; direction: string }): boolean {
  const groups = LINE_FILTERS[key]?.groups;
  if (!groups) return true;
  return groups.some((g) => (!g.direction || g.direction === line.direction) && g.kinds.includes(line.kind));
}

/** A filter as a PostgREST `or` argument, or null for every line. */
export function lineFilterOr(key: string): string | null {
  const groups = LINE_FILTERS[key]?.groups;
  if (!groups) return null;
  return groups
    .map((g) => {
      const kinds = `kind.in.(${g.kinds.join(",")})`;
      return g.direction ? `and(direction.eq.${g.direction},${kinds})` : kinds;
    })
    .join(",");
}

/** Filters of the statement list (« Relevés »). */
export const STATEMENT_STATUS_FILTERS: Record<string, { label: string; statuses: string[] | null }> = {
  tous: { label: "Tous", statuses: null },
  importes: { label: "Importés", statuses: ["imported"] },
  "en-cours": { label: "En cours", statuses: ["awaiting_upload", "uploaded"] },
  refuses: { label: "Refusés ou en échec", statuses: ["rejected", "failed"] },
};

export const STATEMENT_PAGE_SIZE = 20;

export type StatementListQuery = { page: number; compte: string | null; statut: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Page, bank account and status of the list, from the URL (anything else falls back to the default). */
export function statementListQuery(query: Record<string, string | string[] | undefined>): StatementListQuery {
  const text = (v: string | string[] | undefined) => (typeof v === "string" ? v : "");
  const page = /^[1-9][0-9]{0,5}$/.test(text(query.page)) ? Number(text(query.page)) : 1;
  const compte = UUID_RE.test(text(query.compte)) ? text(query.compte) : null;
  const statut = text(query.statut) in STATEMENT_STATUS_FILTERS ? text(query.statut) : "tous";
  return { page, compte, statut };
}

/** The list's URL for a query (defaults left out). */
export function statementListHref(q: StatementListQuery, page: number = q.page): string {
  const params = new URLSearchParams();
  if (q.compte) params.set("compte", q.compte);
  if (q.statut !== "tous") params.set("statut", q.statut);
  if (page > 1) params.set("page", String(page));
  const search = params.toString();
  return `/backoffice/encaissements${search ? `?${search}` : ""}`;
}

export type BankCheck = {
  as_of: string;
  closing_minor: string;
  cash_minor: string;
  unposted_minor: string;
  unposted_lines: number;
  difference_minor: string;
};

/**
 * I9 in words: the bank's closing balance against the cash booked. A gap explained by lines not
 * booked yet (debits to classify, held lines) is normal in M2b-2; an unexplained one is not.
 */
export function bankCheckText(check: BankCheck | null, currency: string): { text: string; tone: Tone } {
  if (!check) return { text: "Export CSV : pas de solde bancaire à rapprocher.", tone: "neutral" };
  if (check.difference_minor !== "0") {
    return {
      text: `Écart non expliqué de ${money(check.difference_minor, currency)} avec le solde de clôture : relevé manquant ou compte déjà approvisionné avant le premier import.`,
      tone: "error",
    };
  }
  if (check.unposted_minor === "0" && check.unposted_lines === 0) {
    return { text: "Solde de clôture rapproché ✓", tone: "ok" };
  }
  const lines =
    check.unposted_lines === 1 ? "1 ligne du compte à classer" : `${check.unposted_lines} lignes du compte à classer`;
  return {
    text: `Solde de clôture rapproché ✓ — écart de ${money(check.unposted_minor, currency)} expliqué par ${lines}`,
    tone: "ok",
  };
}

export type Warning = {
  code: string;
  statements?: number;
  expected_minor?: string;
  actual_minor?: string;
  previous_seq?: string;
  seq?: string;
};

export function warningText(w: Warning, currency: string): string {
  if (w.code === "opening_differs")
    return `Relevé manquant ? Le solde d'ouverture (${money(w.actual_minor, currency)}) ne suit pas le solde de clôture précédent (${money(w.expected_minor, currency)}).`;
  if (w.code === "sequence_gap")
    return `Relevé manquant ? Le numéro de relevé ${w.seq ?? "?"} ne suit pas le précédent (${w.previous_seq ?? "?"}).`;
  if (w.code === "overlap") {
    const n = w.statements ?? 1;
    return `Chevauche ${n === 1 ? "un relevé déjà importé" : `${n} relevés déjà importés`} : les lignes déjà connues sont ignorées.`;
  }
  return w.code;
}

const IMPORT_ERROR: Record<string, string> = {
  wrong_account: "Ce relevé n'est pas celui du compte choisi (IBAN différent).",
  wrong_currency: "Le relevé contient des montants dans une autre devise que celle du compte.",
  currency_mismatch: "Le relevé contient des opérations dans une autre devise que celle du compte.",
  unbalanced:
    "Le relevé ne s'équilibre pas (solde d'ouverture + opérations ≠ solde de clôture) : fichier incomplet ou altéré.",
  missing_balance: "Le relevé n'indique pas son solde d'ouverture ou de clôture.",
  xml_dtd_refused: "Fichier refusé par sécurité : les déclarations DTD ne sont pas acceptées.",
  xml_invalid: "Ce fichier n'est pas un relevé CAMT.053 lisible (XML invalide ou tronqué).",
  xml_encoding: "Ce fichier n'est pas encodé en UTF-8 comme l'exige le format CAMT.053.",
  not_camt053: "Ce fichier n'est pas un relevé CAMT.053.",
  amount_invalid:
    "Un montant est illisible ou a plus de décimales que la devise n'en permet (aucun arrondi n'est fait).",
  date_invalid: "Une date du relevé est illisible.",
  line_invalid: "Une opération du relevé est incomplète (sens, montant ou référence).",
  duplicate_reference_in_file: "La même référence bancaire apparaît deux fois dans le fichier.",
  reference_conflict:
    "Une référence bancaire déjà importée revient avec un autre montant, sens ou date : vérifiez le fichier avec la banque.",
  entry_detail_differs:
    "Une opération déjà importée revient avec un autre niveau de détail (remise ventilée ou non) : le fichier est refusé pour ne pas la comptabiliser deux fois. Importez les relevés de ce compte toujours avec le même niveau de détail.",
  imported_on_other_account:
    "Ce fichier, ou une opération qu'il contient, a déjà été importé sur un autre compte bancaire : vérifiez le compte choisi.",
  future_booking_date: "Une opération est datée après aujourd'hui.",
  csv_header: "Colonnes manquantes : il faut au moins la date, le libellé et le montant (ou débit et crédit).",
  csv_row:
    "Une ligne du CSV est illisible : date JJ/MM/AAAA, montant 1 234,56 (aucun arrondi n'est fait), guillemet non fermé, nombre de colonnes différent de l'en-tête, ou montant négatif dans la colonne Crédit.",
  csv_empty: "Le fichier ne contient aucune opération.",
  csv_encoding:
    "Encodage non reconnu : enregistrez l'export en CSV UTF-8 ou Windows-1252 (pas en texte Unicode/UTF-16).",
  csv_profile_invalid: "Le paramétrage CSV du compte bancaire est invalide : contactez le support.",
  file_too_large: "Relevé trop volumineux : exportez une période plus courte.",
  file_changed: "Le fichier stocké ne correspond pas au fichier déposé : déposez-le à nouveau.",
  bank_account_closed: "Le compte bancaire est clôturé : ses relevés ne sont plus importés.",
  import_failed:
    "L'import a échoué après plusieurs essais. Déposez à nouveau le fichier ; si le problème persiste, contactez le support.",
};

/** French reason of a refused import, with the line number when the worker gave one. */
export function importErrorText(code: string | null, detail: string | null): string {
  const text =
    (code && IMPORT_ERROR[code]) ?? "L'import a été refusé par les contrôles comptables. Contactez le support.";
  const line = detail ? /\bline (\d+)\b/.exec(detail) : null;
  return line ? `${text} (ligne ${line[1]})` : text;
}

/** Errors of create_statement_upload / submit_statement_import, as French text. */
export function uploadErrorText(message: string): string {
  if (message.includes("not allowed")) return "Action non autorisée pour votre rôle.";
  if (message.includes("bank account is closed")) return "Ce compte bancaire est clôturé.";
  if (message.includes("does not match the bank account feed"))
    return "Ce compte reçoit ses relevés dans l'autre format (CAMT.053 ou CSV) : déposez le bon fichier.";
  if (message.includes("already a statement of another bank account"))
    return "Ce fichier a déjà été déposé sur un autre compte bancaire : vérifiez le compte choisi.";
  if (message.includes("unsupported statement file type")) return "Type de fichier non pris en charge (XML ou CSV).";
  if (message.includes("too large")) return "Fichier trop volumineux (500 Mo au plus).";
  if (message.includes("invalid file")) return "Fichier invalide : renommez-le sans « / ».";
  if (message.includes("not uploaded yet")) return "Le fichier n'a pas été envoyé. Réessayez.";
  return "L'envoi a échoué. Réessayez ; si le problème persiste, contactez le support.";
}

/** File types offered by the picker for a bank account's statement format. */
export function acceptFor(feed: string): string {
  return feed === "csv" ? ".csv,.txt" : ".xml";
}

/** A third party's IBAN on screen: its end only (design R10). */
export function maskedIban(iban: string | null): string {
  if (!iban) return "";
  return `IBAN …${iban.slice(-4)}`;
}
