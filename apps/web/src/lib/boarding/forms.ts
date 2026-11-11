/**
 * Pure helpers for the boarding review forms (unit-tested, no floats for money).
 */

const MAX_BIGINT = BigInt("9223372036854775807"); // Postgres bigint

/**
 * Parses an amount typed in euros ("12 345,67", "12345.6", "1 000") into integer minor units.
 * Returns null when the text is not an amount or does not fit a bigint. Never goes through a float.
 */
export function parseEurosToMinor(text: string): bigint | null {
  const compact = text.replace(/[\s  €]/g, "");
  const match = /^(-?)(\d+)(?:[.,](\d{1,2}))?$/.exec(compact);
  if (!match) return null;
  const [, sign, units, decimals = ""] = match;
  const minor = BigInt(units) * BigInt(100) + BigInt(decimals.padEnd(2, "0") || "0");
  if (minor > MAX_BIGINT) return null;
  return sign === "-" ? -minor : minor;
}

export type Proposal = { file_id: string; source_column: string; target: string | null };

/** Field name of the select for one proposal in the mapping form. */
export function mappingField(fileId: string, column: string): string {
  return `map:${fileId}:${encodeURIComponent(column)}`;
}

/**
 * Overrides for `approve_mapping`: {file_id: {source_column: target | ""}} for every select whose
 * value differs from the proposal ("" = not mapped).
 */
export function mappingOverrides(
  proposals: Proposal[],
  values: (field: string) => string | null,
): Record<string, Record<string, string>> {
  const out: Record<string, Record<string, string>> = {};
  for (const p of proposals) {
    const chosen = values(mappingField(p.file_id, p.source_column));
    if (chosen === null) continue;
    if (chosen === (p.target ?? "")) continue;
    (out[p.file_id] ??= {})[p.source_column] = chosen;
  }
  return out;
}

/**
 * Errors of the back-office commands (boarding, bank accounts), as codes: raw database text never
 * reaches the page.
 */
export type ErrorCode =
  | "not_allowed"
  | "totals_mismatch"
  | "reason_required"
  | "mandate_missing"
  | "duplicate_target"
  | "name_taken"
  | "already_submitted"
  | "unsupported_type"
  | "missing_upload"
  | "state_changed"
  | "cut_off_required"
  | "cut_off_future"
  | "opening_mismatch"
  | "opening_plan_missing"
  | "ledger_rejected"
  | "iban_invalid"
  | "close_confirmation"
  | "bic_invalid"
  | "iban_taken"
  | "label_required"
  | "opened_future"
  | "account_holds_money"
  | "already_closed"
  | "already_matched"
  | "file_not_confirmed"
  | "split_not_available"
  | "unknown_file"
  | "not_matched"
  | "payment_allocated"
  | "busy"
  | "designation_invalid"
  | "none_selected"
  | "allocation_changed"
  | "payment_changed"
  | "amount_changed"
  | "proposal_changed"
  | "authorisation_required"
  | "request_required"
  | "not_same_debtor"
  | "not_forwardable"
  | "allocation_busy"
  | "already_reversed"
  | "file_held"
  | "refund_reason_mismatch"
  | "refund_too_much"
  | "refund_iban_required"
  | "refund_name_required"
  | "refund_not_possible"
  | "refund_not_pending"
  | "refund_pending"
  | "already_linked"
  | "link_amount"
  | "link_refused"
  | "not_explainable"
  | "link_before_return"
  | "link_payment_returned"
  | "link_posting_failed"
  | "already_decided"
  | "direct_evidence"
  | "direct_date"
  | "direct_items"
  | "file_not_open"
  | "amount_invalid"
  | "client_funds_exists"
  | "transfers_in_flight"
  | "top_up_accounts"
  | "top_up_not_pending"
  | "date_past"
  | "already_booked"
  | "not_a_fee"
  | "not_an_own_credit"
  | "not_own_credit"
  | "own_account_unknown"
  | "top_up_differs"
  | "not_a_loss"
  | "booking_refused"
  // M2c-2: identities, payout accounts, client documents and events, money terms, the confirmation gate
  | "changed_since_read"
  | "legal_name_required"
  | "siren_invalid"
  | "address_invalid"
  | "capital_invalid"
  | "vat_mismatch"
  | "servicer_identity_incomplete"
  | "text_too_long"
  | "settings_own_account"
  | "cutoff_invalid"
  | "prefix_invalid"
  | "own_account_in_settings"
  | "document_invalid"
  | "document_not_uploaded"
  | "rib_required"
  | "holder_required"
  | "payout_pending"
  | "payout_own_iban"
  | "payout_other_client"
  | "payout_not_pending"
  | "payout_same_person"
  | "payout_iban_mismatch"
  | "payout_not_current"
  | "event_future"
  | "evidence_required"
  | "court_account_only"
  | "payout_court_appointed"
  | "terms_past"
  | "terms_too_early"
  | "terms_start_taken"
  | "schedule_json"
  | "schedule_invalid"
  | "terms_invalid"
  | "clauses_required"
  | "terms_document_required"
  | "claim_type_unknown"
  | "portfolio_other_mandate"
  | "max_days_invalid"
  | "clause_required"
  | "not_ready"
  | "run_pending"
  | "nothing_pending"
  | "run_version_changed"
  | "run_not_draft"
  | "run_approval_in_progress"
  | "run_not_cancellable"
  | "run_already_sent"
  | "run_none_selected"
  | "run_busy"
  | "run_retry"
  | "execution_date_invalid"
  | "credit_note_on_credit_note"
  | "credit_note_nothing_left"
  | "credit_note_in_flight"
  | "credit_note_run_in_flight"
  | "credit_note_file"
  | "credit_note_amount"
  | "credit_note_too_much"
  | "credit_note_changed"
  | "credit_note_category"
  | "transfer_nothing_to_file"
  | "transfer_cash_not_covered"
  | "transfer_no_closing_balance"
  | "transfer_not_paying_account"
  | "transfer_already_downloaded"
  | "transfer_hash_mismatch"
  | "transfer_not_ready"
  | "transfer_not_downloaded"
  | "transfer_attestation_required"
  | "transfer_debit_seen"
  | "transfer_statement_not_imported"
  | "transfer_version_changed"
  | "transfer_already_sent"
  | "transfer_pain_version"
  | "payee_check_four_eyes"
  | "payee_check_cleared"
  | "transfer_no_statement_evidence"
  | "transfer_same_person"
  | "transfer_cancel_already_requested"
  | "transfer_cancel_not_requested"
  | "transfer_file_stale"
  | "transfer_file_blocked"
  | "transfer_file_holds_cancelled"
  | "run_payout_in_downloaded_file"
  | "refund_payee_name_not_epc"
  | "refund_iban_not_sepa"
  | "refund_in_downloaded_file"
  | "transfer_cancellation_request_required"
  | "transfer_not_in_downloaded_file"
  | "transfer_not_live"
  | "transfer_late_reason_too_long"
  | "payee_check_not_a_payout"
  | "transfer_file_not_executed"
  | "transfer_batch_ambiguous"
  | "unknown";

const ERROR_TEXT: Record<ErrorCode, string> = {
  not_allowed: "Action non autorisée pour votre rôle.",
  totals_mismatch:
    "Les totaux ne concordent pas avec ceux du cédant : indiquez un motif pour intégrer quand même.",
  reason_required: "Indiquez un motif.",
  mandate_missing:
    "Aucun mandat actif ne couvre ce portefeuille (art. R124-3 CPCE) : la confirmation est impossible.",
  duplicate_target: "Deux colonnes d'un même fichier ont la même cible.",
  name_taken: "Un autre fichier porte déjà ce nom dans ce lot : renommez-le.",
  already_submitted: "Ce lot a déjà été déposé. Ouvrez-le depuis la liste des reprises.",
  unsupported_type: "Type de fichier non pris en charge (CSV, Excel, largeur fixe ou zip).",
  missing_upload: "Un fichier n'a pas été envoyé. Réessayez.",
  state_changed: "Le lot a changé d'état entre-temps. Rechargez la page.",
  cut_off_required:
    "La date d'arrêté du portefeuille est obligatoire et ne peut pas être dans le futur : abandonnez ce lot et créez-en un avec une date d'arrêté passée.",
  cut_off_future: "La date d'arrêté ne peut pas être dans le futur : le fichier décrit le portefeuille à une date passée.",
  opening_mismatch:
    "Les soldes d'ouverture ne correspondent pas au rapport qualité : abandonnez ce lot et déposez à nouveau le fichier.",
  opening_plan_missing:
    "Ce lot a été intégré avant la comptabilisation des soldes d'ouverture : annulez l'intégration, puis déposez à nouveau le fichier.",
  ledger_rejected: "La comptabilité a refusé l'opération. Contactez le support.",
  iban_invalid: "IBAN invalide : vérifiez la saisie (27 caractères pour un compte en France).",
  close_confirmation: "Pour confirmer la clôture, saisissez les 4 derniers caractères de l'IBAN de ce compte.",
  bic_invalid: "BIC invalide : 8 ou 11 caractères (lettres et chiffres).",
  iban_taken:
    "Cet IBAN est déjà enregistré : dans cette devise, ou pour un autre usage (un IBAN est soit un compte de fonds de tiers, soit le compte propre du cabinet).",
  label_required: "Indiquez un libellé (100 caractères au plus).",
  opened_future: "La date d'ouverture ne peut pas être dans le futur.",
  account_holds_money:
    "Ce compte détient encore des fonds de tiers : il ne peut pas être clôturé tant que son solde n'est pas nul.",
  already_closed: "Ce compte est déjà clôturé. Rechargez la page.",
  already_matched: "Ce paiement est déjà affecté à un dossier : désaffectez-le d'abord. Rechargez la page.",
  file_not_confirmed:
    "Ce dossier n'est pas encore confirmé : le paiement lui sera rapproché automatiquement à la confirmation du lot.",
  split_not_available:
    "Un paiement est affecté à un seul dossier pour l'instant : la répartition sur plusieurs dossiers viendra avec l'imputation.",
  unknown_file: "Dossier introuvable pour ce servicer.",
  not_matched: "Ce paiement n'est affecté à aucun dossier. Rechargez la page.",
  payment_allocated: "Une partie de ce paiement est déjà imputée : annulez d'abord l'imputation.",
  busy: "Ce paiement est en cours de rapprochement automatique : réessayez dans un instant.",
  designation_invalid: "Les factures désignées doivent appartenir à ce dossier.",
  none_selected: "Cochez au moins un paiement.",
  allocation_changed: "L'imputation de ce paiement a changé entre-temps : rechargez la page.",
  payment_changed: "Ce paiement a changé entre-temps : rechargez la page.",
  amount_changed: "Le montant restant de ce paiement a changé entre-temps : rechargez la page.",
  proposal_changed: "La proposition d'avoir a changé entre-temps : rechargez la page.",
  authorisation_required: "Choisissez l'autorisation du juge, classée dans ce dossier.",
  request_required: "Choisissez la demande écrite du débiteur, classée dans l'un des deux dossiers.",
  not_same_debtor: "L'autre dossier doit être un dossier ouvert du même débiteur, chez le même client.",
  not_forwardable:
    "Ce paiement ne peut pas être reversé au client : seul un paiement sans imputation, sur un dossier rappelé ou antérieur à l'arrêté, peut l'être.",
  allocation_busy: "Une imputation est en cours pour ce servicer : réessayez dans un instant.",
  already_reversed: "Cette imputation a déjà été annulée entre-temps : rechargez la page.",
  file_held:
    "Le dossier est bloqué (surendettement ou procédure collective) : ni reversement au client ni compensation tant que le blocage est en place. Rechargez la page.",
  refund_reason_mismatch: "Ce motif de remboursement ne correspond pas à la situation du paiement : rechargez la page.",
  refund_too_much: "Le montant dépasse ce qui reste du paiement.",
  refund_iban_required: "La banque n'a pas transmis l'IBAN du payeur : saisissez l'IBAN du bénéficiaire.",
  refund_name_required:
    "La banque n'a pas transmis le nom du payeur : saisissez le nom du bénéficiaire (140 caractères au plus).",
  refund_not_possible:
    "Ce paiement ne peut pas être remboursé depuis ici (il attend son imputation, ou un remboursement est déjà demandé). Rechargez la page.",
  refund_not_pending: "Ce remboursement n'est plus en attente : rechargez la page.",
  refund_pending: "Un remboursement est demandé pour ce paiement : annulez-le d'abord.",
  already_linked: "Cette ligne a déjà été traitée : rechargez la page.",
  link_amount:
    "Le montant ne convient pas : il dépasse ce qui reste du paiement, ou n'est pas celui du remboursement demandé.",
  link_refused:
    "Ce rapprochement n'est pas possible pour cette ligne (sens, compte bancaire, date ou état) : vérifiez la ligne et rechargez la page.",
  not_explainable:
    "Ce retour nomme l'un de nos paiements (ou c'est notre remboursement) : il ne se classe pas sans comptabiliser, liez-le au paiement concerné.",
  link_before_return:
    "Cette ligne est antérieure à un retour déjà comptabilisé sur ce paiement : elle ne peut pas être liée à sa date.",
  link_payment_returned:
    "Le paiement de ce remboursement a été retourné par la banque : ce montant revenu ne peut pas encore être comptabilisé.",
  link_posting_failed: "La comptabilisation a été refusée pour cette ligne : vérifiez-la ou signalez-la au support.",
  already_decided: "Cette ligne a déjà été traitée : rechargez la page.",
  direct_evidence: "Choisissez le relevé du client, classé dans ce dossier.",
  direct_date: "La date doit être passée, et postérieure à la reprise du dossier.",
  direct_items: "Les factures désignées doivent appartenir à ce dossier.",
  file_not_open: "Le dossier n'est pas ouvert.",
  amount_invalid: "Montant invalide : saisissez un montant positif en euros (ex. 120,50).",
  client_funds_exists:
    "Un compte de fonds de tiers est déjà actif dans cette devise : le cabinet a choisi un seul compte dédié par devise pour recevoir et reverser les fonds des clients.",
  transfers_in_flight:
    "Un virement depuis ou vers ce compte est en cours (approvisionnement non encore crédité) : annulez-le ou attendez son crédit.",
  top_up_accounts:
    "L'approvisionnement part d'un compte propre actif vers le compte de fonds de tiers actif de la même devise.",
  top_up_not_pending: "Cet approvisionnement n'est plus en attente : rechargez la page.",
  date_past: "La date d'exécution demandée ne peut pas être passée.",
  already_booked: "Cette ligne est déjà comptabilisée : rechargez la page.",
  not_a_fee:
    "Seul un débit classé « Frais ou autre débit » se comptabilise en frais bancaires : un virement émis par le cabinet n'en est pas un.",
  not_an_own_credit: "Seul un crédit reçu du compte propre du cabinet se comptabilise en approvisionnement.",
  not_own_credit:
    "Seul un crédit reçu du compte propre du cabinet ou d'un compte de reversement d'un client, ni comptabilisé ni classé, peut devenir le paiement d'un débiteur : rechargez la page.",
  own_account_unknown:
    "Ce crédit ne vient d'aucun compte propre enregistré : enregistrez le compte propre, ou classez la ligne avec une explication.",
  top_up_differs:
    "Ce crédit porte la référence d'un approvisionnement d'un autre montant ou d'un autre compte : annulez l'approvisionnement demandé, puis comptabilisez le crédit.",
  not_a_loss: "Ce retour ne dépasse pas ce qui reste du paiement : liez-le au paiement (retour total ou partiel).",
  booking_refused: "Cette comptabilisation n'est pas possible pour cette ligne : vérifiez-la et rechargez la page.",
  changed_since_read: "Les données ont changé depuis leur affichage : rechargez la page et recommencez.",
  legal_name_required: "La raison sociale est obligatoire (200 caractères au plus).",
  siren_invalid: "SIREN invalide : 9 chiffres.",
  address_invalid: "Adresse invalide : ligne d'adresse, code postal (5 chiffres en France), ville et pays.",
  capital_invalid: "Capital social invalide : un montant positif en euros.",
  vat_mismatch: "Le numéro de TVA intracommunautaire ne correspond pas au SIREN.",
  servicer_identity_incomplete:
    "L'identité du cabinet s'enregistre complète : SIREN, forme juridique, capital (SARL, SA, SAS…), ville du RCS, numéro de TVA, professionnel.",
  text_too_long: "Un texte est trop long.",
  settings_own_account: "Les factures se règlent sur un compte propre actif du cabinet, jamais sur le compte dédié.",
  cutoff_invalid: "Heure limite invalide : HH:MM, pour un compte de fonds de tiers.",
  prefix_invalid: "Le préfixe des factures compte 2 à 6 lettres majuscules.",
  own_account_in_settings:
    "Ce compte propre reçoit le paiement des factures (paramètres de facturation) : choisissez-en un autre d'abord.",
  document_invalid: "Fichier refusé : PDF, PNG ou JPEG, avec un nom de fichier simple.",
  document_not_uploaded: "Le fichier n'a pas été envoyé. Réessayez.",
  rib_required: "Le RIB du client (document « RIB » de ce client) est obligatoire.",
  holder_required: "Le titulaire, tel qu'il figure sur le RIB, est obligatoire (70 caractères au plus).",
  payout_pending: "Un IBAN attend déjà sa confirmation pour ce client et cette devise : confirmez-le ou refusez-le d'abord.",
  payout_own_iban: "Cet IBAN est l'un des comptes bancaires du cabinet.",
  payout_other_client: "Cet IBAN est déjà le compte de reversement d'un autre client.",
  payout_not_pending: "Cet IBAN n'attend plus de confirmation. Rechargez la page.",
  payout_same_person: "Vous avez proposé cet IBAN : une autre personne doit le confirmer.",
  payout_iban_mismatch: "L'IBAN saisi n'est pas celui proposé : vérifiez le RIB et refusez la proposition si elle est fausse.",
  payout_not_current: "Ce compte n'est plus le compte de reversement en cours. Rechargez la page.",
  event_future: "La date de l'événement ne peut pas être dans le futur.",
  evidence_required: "Le justificatif (document « Justificatif » de ce client) est obligatoire.",
  court_account_only: "Seul le compte d'un mandataire de justice (liquidateur) peut être indiqué ici.",
  payout_court_appointed:
    "Un mandataire de justice est enregistré pour ce client (liquidation judiciaire, ou compte d'un mandataire désigné) : ses comptes de reversement sont confirmés, refusés ou retirés par un second administrateur du cabinet, et non depuis l'espace du client (règle du cabinet ; en liquidation, les droits du client sont exercés par le liquidateur, art. L641-9 C. com.).",
  terms_past: "Une nouvelle version commence au plus tôt demain : les conditions ne sont jamais rétroactives.",
  terms_too_early:
    "Une nouvelle version commence au plus tôt demain (heure de Paris) : les encaissements d'aujourd'hui restent aux conditions en vigueur.",
  terms_start_taken: "Une version en vigueur commence déjà ce jour-là : choisissez une date à venir.",
  schedule_json: "Le barème n'est pas un JSON lisible : vérifiez les guillemets, virgules et accolades.",
  schedule_invalid:
    "Barème invalide (commission-1) : taux en texte (« 0.15 », 4 décimales au plus, entre 0 et 1), paliers croissants dont seul le dernier est ouvert, identifiants distincts, la dernière règle s'applique à tout.",
  terms_invalid:
    "Conditions de reversement invalides (remittance-1) : fréquence bimensuelle ou hebdomadaire (jour 1 à 5), clauses de compensation et de reprise (ou aucune), délai de paiement des factures de 0 à 45 jours.",
  clauses_required: "Les références des clauses de rémunération et de reversement sont obligatoires (art. R124-3 3° et 4° CPCE).",
  terms_document_required: "Le mandat signé (document « Mandat » de ce client) est obligatoire.",
  claim_type_unknown: "Le barème nomme un type de créance inconnu.",
  portfolio_other_mandate: "Le barème nomme un portefeuille d'un autre mandat.",
  max_days_invalid:
    "Le délai de reversement est de 1 à 30 jours : jamais plus d'un mois, engagement du cabinet (l'art. R124-6 CPCE prévoit un mois, sauf convention contraire).",
  clause_required: "La référence de la clause est obligatoire (200 caractères au plus).",
  not_ready:
    "Le portefeuille n'est pas prêt pour la confirmation : complétez d'abord les éléments listés (identités, conditions du mandat).",
  run_pending:
    "Un reversement de ce client est déjà en cours (brouillon, validé ou transmis) : un seul à la fois par client et par devise.",
  nothing_pending: "Rien à reverser pour ce client : aucun encaissement n'attend.",
  run_version_changed: "Le reversement a changé depuis l'affichage de la page : rechargez-la puis recommencez.",
  run_not_draft: "Ce reversement n'est plus un brouillon.",
  run_approval_in_progress: "La validation de ce reversement est en cours : attendez son résultat.",
  run_not_cancellable: "Seul un reversement validé, dont le virement n'est pas encore débité, peut être annulé.",
  run_already_sent:
    "Le fichier de virements a déjà été téléchargé : l'annulation demande l'attestation que la banque n'a pas exécuté le virement.",
  run_none_selected: "Cochez au moins un reversement à valider.",
  run_busy:
    "Un traitement est en cours sur ce reversement ou pour ce cabinet (préparation, validation, imputation ou établissement du relevé) : réessayez dans un instant.",
  run_retry: "La date a changé (minuit) pendant l'opération : rien n'a été enregistré. Réessayez.",
  execution_date_invalid: "La date d'exécution demandée doit être un jour ouvré, à partir d'aujourd'hui.",
  credit_note_on_credit_note: "Un avoir ne se rectifie pas par un autre avoir.",
  credit_note_nothing_left: "Cette facture est déjà entièrement rectifiée : il ne reste rien à créditer.",
  credit_note_in_flight:
    "Un reversement validé compense cette facture sur son virement, pas encore débité : attendez son débit, ou annulez ce reversement.",
  credit_note_run_in_flight:
    "Le reversement qui a émis cette facture est validé mais pas encore débité : il peut encore être annulé. Attendez son débit, ou annulez-le, avant d'émettre un avoir.",
  credit_note_file: "Ce dossier n'a plus rien de facturé sur cette facture.",
  credit_note_amount: "Indiquez un montant HT positif, au centime près (par exemple 30,00).",
  credit_note_too_much: "Le montant dépasse ce qui reste facturé (sur la facture, ou sur le dossier choisi).",
  credit_note_changed: "La facture a changé depuis l'affichage de la page (un autre avoir ?) : rechargez-la puis recommencez.",
  credit_note_category: "Choisissez le motif de l'avoir dans la liste.",
  transfer_nothing_to_file: "Aucun virement à mettre dans un fichier : ceux qui attendent sont retenus (motif affiché).",
  transfer_cash_not_covered:
    "Le solde du compte dédié ne couvre pas ce fichier (solde du dernier relevé, moins ce qui est déjà en route) : importez le dernier relevé, puis recommencez.",
  transfer_no_closing_balance: "Aucun relevé avec solde de clôture n'est importé pour ce compte : importez-en un d'abord.",
  transfer_not_paying_account: "Ce compte ne paie pas de fichier de virements (seul le compte dédié actif en euros).",
  transfer_already_downloaded:
    "Ce fichier a déjà été téléchargé : confirmez l'avertissement pour le télécharger de nouveau, et ne le déposez pas deux fois.",
  transfer_hash_mismatch:
    "Le fichier stocké ne correspond pas à celui qui a été généré : il n'est pas servi. Prévenez le support.",
  transfer_not_ready: "Le fichier est en cours d'écriture : réessayez dans quelques secondes.",
  transfer_not_downloaded: "Ce fichier n'a pas été téléchargé : il est simplement remplacé, sans attestation.",
  transfer_attestation_required:
    "Le fichier a été téléchargé : cochez l'attestation (non déposé, ou rejeté par la banque) pour l'annuler.",
  transfer_debit_seen:
    "Un relevé montre déjà le débit d'un virement de ce fichier (la banque l'a exécuté) : rien n'est annulé (risque de double paiement).",
  transfer_statement_not_imported:
    "Importez d'abord le relevé du jour d'exécution demandé : il doit montrer que la banque n'a pas débité ce virement.",
  transfer_version_changed: "Le fichier a changé depuis l'affichage de la page : rechargez-la.",
  transfer_already_sent: "Ce fichier est déjà marqué comme transmis.",
  transfer_pain_version: "Choisissez pain.001.001.09 ou pain.001.001.03.",
  payee_check_four_eyes:
    "Le signalement doit être levé par une autre personne : ni celle qui l'a enregistré, ni celles qui ont proposé ou confirmé cet IBAN.",
  payee_check_cleared: "Ce signalement est déjà levé.",
  // M2c-6a review (T1): a downloaded file, or one of its transfers, is cancelled with the statement's evidence and four eyes
  // review round 2 (D1): those days must be over — the statement imported after them (a CSV proves nothing of its last day)
  transfer_no_statement_evidence:
    "Importez d'abord le relevé du compte couvrant le jour d'exécution demandé et le jour ouvré suivant, une fois ces journées terminées (un relevé importé le jour même ne prouve rien pour ce jour, un CSV rien pour son dernier jour) : il doit montrer que la banque n'a rien débité (ou qu'elle a rejeté le virement).",
  transfer_same_person:
    "L'annulation doit être confirmée par une autre personne que celle qui l'a demandée (deux personnes, chacune avec sa double authentification).",
  transfer_cancel_already_requested:
    "Une demande d'annulation est déjà en cours : une autre personne doit la confirmer. Rechargez la page.",
  transfer_cancel_not_requested: "Aucune demande d'annulation n'est en cours (déjà confirmée ou retirée) : rechargez la page.",
  transfer_cancellation_request_required:
    "Ce fichier a été téléchargé : son annulation se demande (« Demander l'annulation »), puis une autre personne la confirme, relevé à l'appui.",
  transfer_not_in_downloaded_file:
    "Ce virement n'est plus dans un fichier téléchargé (déjà annulé, débité, ou son fichier remplacé) : rechargez la page.",
  transfer_not_live: "Ce fichier n'est plus en cours (remplacé, rejeté ou en échec) : rechargez la page.",
  transfer_late_reason_too_long: "Le motif du retard est trop long (2 000 caractères au plus).",
  payee_check_not_a_payout: "Un nom non concordant se signale sur un reversement (le titulaire de son compte de reversement).",
  // M2c-6a review (T2): the download re-ran the generation's checks and replaced the file
  transfer_file_stale:
    "Date d'exécution dépassée : le fichier n'a pas été servi et il est remplacé. Régénérez-le (nouveau numéro, nouvelle date).",
  transfer_file_blocked:
    "Des virements de ce fichier ne passent plus les contrôles depuis sa génération (IBAN changé, nom non concordant, montant plus couvert…) : le fichier n'a pas été servi et il est remplacé. Régénérez-le.",
  transfer_file_holds_cancelled:
    "Un virement de ce fichier a été annulé depuis son téléchargement : le fichier n'est plus servi et ne doit pas être déposé (ni marqué comme transmis). Si la banque n'en a rien exécuté, demandez l'annulation du fichier.",
  // M2c-6a review, round 2 (D2, D3): one transfer is cancelled only from an executed file, on a batch debit only when it
  // singles it out
  transfer_file_not_executed:
    "Les relevés ne montrent aucun débit ni retour de ce fichier : la banque n'en a rien exécuté. N'annulez pas un virement seul (le fichier, toujours valable, le paierait encore) : demandez l'annulation du fichier entier.",
  transfer_batch_ambiguous:
    "La banque a débité ce lot en une seule ligne, sans le détail des virements, et d'autres virements du lot (un seul ou plusieurs ensemble) font le même montant que celui-ci : rien ne prouve lequel n'a pas été payé. Demandez à la banque le détail du lot avant d'annuler quoi que ce soit.",
  run_payout_in_downloaded_file:
    "Le virement de ce reversement est dans un fichier déjà téléchargé : faites d'abord annuler ce virement (une demande, puis la confirmation d'une autre personne, relevé à l'appui), puis annulez le reversement.",
  // M2c-6a review (T3): a refund the transfer file cannot carry
  refund_payee_name_not_epc:
    "Le nom du bénéficiaire doit contenir au moins une lettre latine ou un chiffre (le format SEPA n'accepte que l'alphabet latin de base).",
  refund_iban_not_sepa:
    "Cet IBAN est hors de la zone SEPA : le remboursement ne peut pas partir dans un fichier de virements. Choisissez « Je l'exécute moi-même ».",
  refund_in_downloaded_file:
    "Le virement de ce remboursement est dans un fichier déjà téléchargé : faites d'abord annuler ce virement depuis le fichier (« Virements » : une demande, puis la confirmation d'une autre personne, relevé à l'appui), puis le remboursement.",
  unknown: "L'action a échoué. Réessayez ; si le problème persiste, contactez le support.",
};

/** Code for an error raised by a boarding command (order matters: most specific first). */
export function commandErrorCode(message: string): ErrorCode {
  if (message.includes("not allowed")) return "not_allowed";
  if (message.includes("cut-off date is required")) return "cut_off_required";
  if (message.includes("cut-off date cannot be in the future")) return "cut_off_future";
  if (message.includes("roll it back and board the file again")) return "opening_plan_missing";
  if (message.includes("opening balances do not reconcile") || message.includes("without an opening plan"))
    return "opening_mismatch";
  if (message.includes("do not reconcile")) return "totals_mismatch";
  if (message.includes("reason is required")) return "reason_required";
  if (message.includes("CPCE R124-3")) return "mandate_missing";
  if (message.includes("not ready for confirmation")) return "not_ready";
  if (message.includes("same target")) return "duplicate_target";
  if (message.includes("another file with this name")) return "name_taken";
  if (message.includes("only be added to a draft batch") || message.includes("control totals can only change"))
    return "already_submitted";
  if (message.includes("unsupported file type")) return "unsupported_type";
  if (message.includes("not uploaded yet")) return "missing_upload";
  if (message.includes("expected") || message.includes("cannot be abandoned") || message.includes("only a committed"))
    return "state_changed";
  if (message.startsWith("ledger:")) return "ledger_rejected";
  return "unknown";
}

export function errorText(code: ErrorCode): string {
  return ERROR_TEXT[code] ?? ERROR_TEXT.unknown;
}

/** Result of a server action called from an ActionForm. */
export type ActionResult = { ok: true } | { error: ErrorCode };

/** Percentages in French notation: 0.925 -> "92,5 %". */
export function formatPct(ratio: number): string {
  return new Intl.NumberFormat("fr-FR", { style: "percent", maximumFractionDigits: 1 }).format(ratio);
}
