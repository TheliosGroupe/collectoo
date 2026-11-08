import registry from "./targets.json";

/** Mapping targets offered in the review (generated from the worker's registry). */
export type Target = { id: string; type: string; description: string };

const LABEL_FR: Record<string, string> = {
  "party.display_name": "Débiteur : nom ou raison sociale",
  "party.first_name": "Débiteur : prénom",
  "party.siren": "Débiteur : SIREN",
  "party.siret": "Débiteur : SIRET",
  "party.iban": "Débiteur : IBAN",
  "contact.email": "Contact : e-mail",
  "contact.phone": "Contact : téléphone",
  "contact.address_line": "Contact : adresse",
  "contact.postcode": "Contact : code postal",
  "contact.city": "Contact : ville",
  "account.external_ref": "Compte : référence client",
  "claim_item.kind": "Pièce : type (facture, avoir…)",
  "claim_item.ref": "Pièce : numéro",
  "claim_item.issue_date": "Pièce : date d'émission",
  "claim_item.due_date": "Pièce : date d'échéance",
  "claim_item.amount": "Pièce : montant",
  "claim_item.amount_paid": "Pièce : montant déjà payé",
  "claim_item.currency": "Pièce : devise",
  "claim_item.period": "Pièce : période (loyer)",
};

export const TARGETS: readonly Target[] = registry;

export function targetLabel(id: string | null): string {
  if (!id) return "Non repris";
  const known = LABEL_FR[id];
  if (known) return known;
  const target = TARGETS.find((t) => t.id === id);
  // EU-template fields keep the Regulation's field number and name.
  return target ? target.description.replace(/^EU NPL template /, "Modèle UE ") : id;
}

export type TargetGroup = { label: string; targets: Target[] };

export function targetGroups(): TargetGroup[] {
  return [
    { label: "Données de gestion", targets: TARGETS.filter((t) => !t.id.startsWith("eba.")) },
    { label: "Modèle UE (règlement 2023/2083)", targets: TARGETS.filter((t) => t.id.startsWith("eba.")) },
  ];
}
