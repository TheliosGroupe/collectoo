/** Boarding batch states (docs/DOMAIN.md §4.4) as shown in the back-office. */
export type BatchStatus =
  | "draft"
  | "uploaded"
  | "profiled"
  | "mapping_proposed"
  | "mapping_approved"
  | "transformed"
  | "needs_fix"
  | "validated"
  | "staged"
  | "committed"
  | "confirming"
  | "confirmed"
  | "rolled_back"
  | "abandoned";

export const STATUS_LABEL: Record<BatchStatus, string> = {
  draft: "Brouillon",
  uploaded: "Fichiers reçus",
  profiled: "Fichiers analysés",
  mapping_proposed: "Mapping à valider",
  mapping_approved: "Mapping validé",
  transformed: "Données transformées",
  needs_fix: "À corriger",
  validated: "Contrôles passés",
  staged: "Prêt à intégrer",
  committed: "Intégré, à confirmer",
  confirming: "Confirmation en cours",
  confirmed: "Confirmé",
  rolled_back: "Annulé",
  abandoned: "Abandonné",
};

/** States in which the worker is busy: the page refreshes itself until the next step. */
const PROCESSING: ReadonlySet<string> = new Set([
  "uploaded",
  "profiled",
  "mapping_approved",
  "transformed",
  "validated",
  "confirming",
]);

export function statusLabel(status: string): string {
  return STATUS_LABEL[status as BatchStatus] ?? status;
}

export function isProcessing(status: string): boolean {
  return PROCESSING.has(status);
}

export type Tone = "neutral" | "busy" | "action" | "ok" | "error";

export function statusTone(status: string): Tone {
  if (isProcessing(status)) return "busy";
  if (status === "mapping_proposed" || status === "staged" || status === "committed") return "action";
  if (status === "confirmed") return "ok";
  if (status === "needs_fix" || status === "rolled_back" || status === "abandoned") return "error";
  return "neutral";
}

/** Validation issue codes (worker/src/collectoo_worker/boarding/specs/validation.v2.yaml). */
const ISSUE_LABEL: Record<string, string> = {
  impossible_date: "Date impossible",
  bad_date: "Date illisible",
  bad_amount: "Montant illisible",
  unknown_value: "Valeur inconnue",
  invalid_siren: "SIREN invalide",
  invalid_siret: "SIRET invalide",
  invalid_iban: "IBAN invalide",
  invalid_email: "E-mail invalide",
  bad_phone: "Téléphone invalide",
  invalid_postcode_fr: "Code postal invalide",
  invalid_currency: "Devise invalide",
  missing_required: "Donnée obligatoire manquante",
  missing_recommended: "Donnée recommandée manquante",
  missing_contact: "Ni e-mail ni téléphone (courrier seulement)",
  duplicate_row: "Ligne en double (reprise une fois)",
  duplicate_document: "Pièce en double pour le même compte",
  conflicting_document: "Même pièce pour le même compte avec un autre montant, réglé, devise ou échéance",
  mixed_date_format: "Format de date différent du reste de la colonne",
  negative_amount: "Montant négatif",
  overpaid: "Payé supérieur au montant",
  credit_note_paid: "Montant réglé sur un avoir",
  mixed_currency_account: "Plusieurs devises pour un même compte",
  unsupported_currency: "Devise non acceptée",
  duplicate_loan: "Identifiant de prêt en double avec des valeurs différentes",
  duplicate_eba_table:
    "Plusieurs fichiers pour la même table du modèle UE : refaire la reprise avec un seul fichier par table",
  bad_month_offset: "Mois de l'historique de recouvrement invalide (nombre entier de mois, 1 ou plus)",
  sub_cent_amount: "Montant avec plus de 2 décimales (arrondi au centime)",
  components_exceed_legal_balance: "Principal, intérêts et autres soldes supérieurs au solde légal (3.12)",
  unassigned_claim_type: "Type de créance non déterminé",
  unknown_legal_regime: "Régime juridique non déterminé (date du contrat manquante)",
  broken_reference: "Référence vers un autre fichier introuvable",
  eba_mandatory_missing: "Champ obligatoire du modèle UE manquant",
  file_not_boarded: "Fichier non repris : largeur fixe sans description des colonnes, ou classeur vide",
};

export function issueLabel(code: string): string {
  return ISSUE_LABEL[code] ?? code;
}
