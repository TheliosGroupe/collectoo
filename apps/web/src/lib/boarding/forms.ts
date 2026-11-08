/**
 * Pure helpers for the boarding review forms (unit-tested, no floats for money).
 */

/**
 * Parses an amount typed in euros ("12 345,67", "12345.6", "1 000") into integer minor units.
 * Returns null when the text is not an amount. Never goes through a float.
 */
export function parseEurosToMinor(text: string): bigint | null {
  const compact = text.replace(/[\s  €]/g, "");
  const match = /^(-?)(\d+)(?:[.,](\d{1,2}))?$/.exec(compact);
  if (!match) return null;
  const [, sign, units, decimals = ""] = match;
  const minor = BigInt(units) * BigInt(100) + BigInt(decimals.padEnd(2, "0") || "0");
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

/** French message for an error raised by a boarding command (back-office copy). */
export function commandError(message: string): string {
  if (message.includes("not allowed")) return "Action non autorisée pour votre rôle.";
  if (message.includes("a reason is required") || message.includes("reason is required"))
    return "Indiquez un motif.";
  if (message.includes("CPCE R124-3"))
    return "Aucun mandat actif ne couvre ce portefeuille (art. R124-3 CPCE) : la confirmation est impossible.";
  if (message.includes("do not reconcile"))
    return "Les totaux ne correspondent pas à ceux du cédant : indiquez un motif pour intégrer quand même.";
  if (message.includes("same target")) return "Deux colonnes d'un même fichier ont la même cible.";
  if (message.includes("expected")) return "Le lot a changé d'état entre-temps. Rechargez la page.";
  return `L'action a échoué : ${message}`;
}
