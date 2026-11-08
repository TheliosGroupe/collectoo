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

/** What a statement line is, and where it stands in M2b-2 (payments are booked; the rest waits). */
export function lineState(line: { kind: string; direction: string; has_payment: boolean }): {
  kind: string;
  state: string;
  tone: Tone;
} {
  const kind = LINE_KIND[line.kind] ?? line.kind;
  if (line.has_payment) return { kind, state: "Comptabilisé · à affecter", tone: "ok" };
  if (line.kind === "suspected_duplicate") return { kind, state: "Retenu : doublon possible", tone: "action" };
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

export const LINE_FILTERS: Record<string, { label: string; kinds: string[] | null }> = {
  toutes: { label: "Toutes", kinds: null },
  encaissements: { label: "Encaissements", kinds: ["debtor_credit", "batch_unsplit"] },
  "a-classer": { label: "À classer", kinds: ["return", "refund_out", "other_debit", "psp_payout"] },
  doublons: { label: "Doublons possibles", kinds: ["suspected_duplicate"] },
};

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
  future_booking_date: "Une opération est datée après aujourd'hui.",
  csv_header: "Colonnes manquantes : il faut au moins la date, le libellé et le montant (ou débit et crédit).",
  csv_row: "Une ligne du CSV est illisible (date JJ/MM/AAAA, montant 1 234,56 ; aucun arrondi n'est fait).",
  csv_empty: "Le fichier ne contient aucune opération.",
  csv_profile_invalid: "Le paramétrage CSV du compte bancaire est invalide.",
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
