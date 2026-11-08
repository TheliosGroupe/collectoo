/**
 * File profiles written by the worker (worker/src/collectoo_worker/jobs/boarding.py profile_file):
 * a table ({columns, ...}) for CSV, {sheets: {name: table}} for Excel, {needs_layout} for
 * fixed-width files and {not_profiled: "zip"} for document archives.
 */

export type ProfileColumn = {
  name: string;
  non_null: number;
  null_pct: number;
  distinct: number;
  type_guess: string;
  issues: Record<string, unknown>;
  top_values?: { value: string; count: number }[];
};

type Table = { row_count: number; duplicate_rows: number; columns: ProfileColumn[] };

export type FileProfile =
  | { kind: "table"; table: Table; sheet?: string }
  | { kind: "empty_workbook" }
  | { kind: "documents" }
  | { kind: "needs_layout" }
  | { kind: "pending" };

function isTable(value: unknown): value is Table {
  return typeof value === "object" && value !== null && Array.isArray((value as Table).columns);
}

/** Same choice as the worker's mappable_profile(): the file itself or its first non-empty sheet. */
export function readProfile(raw: unknown): FileProfile {
  if (raw === null || typeof raw !== "object") return { kind: "pending" };
  if (isTable(raw)) return { kind: "table", table: raw };
  const obj = raw as Record<string, unknown>;
  if (obj.sheets && typeof obj.sheets === "object") {
    const sheets = obj.sheets as Record<string, unknown>;
    // jsonb sorts keys: the workbook order is in sheet_order (same sheet as the worker reads).
    const order = Array.isArray(obj.sheet_order) ? (obj.sheet_order as string[]) : Object.keys(sheets);
    for (const sheet of order) {
      const table = sheets[sheet];
      if (isTable(table) && table.row_count > 0) return { kind: "table", table, sheet };
    }
    return { kind: "empty_workbook" };
  }
  if (obj.needs_layout) return { kind: "needs_layout" };
  if (obj.not_profiled) return { kind: "documents" };
  return { kind: "pending" };
}

const TYPE_FR: Record<string, string> = {
  date_fr: "Date jj/mm/aaaa",
  date_iso: "Date aaaa-mm-jj",
  date_dotted: "Date jj.mm.aaaa",
  siret: "SIRET",
  siren: "SIREN",
  postcode_fr: "Code postal",
  iban: "IBAN",
  email: "E-mail",
  phone_fr: "Téléphone",
  integer: "Nombre entier",
  decimal_comma: "Nombre décimal (virgule)",
  decimal_dot: "Nombre décimal (point)",
  text: "Texte",
};

const COLUMN_ISSUE_FR: Record<string, string> = {
  mixed_date_formats: "formats de date mélangés",
  impossible_dates: "dates impossibles",
  luhn_invalid: "clé de contrôle invalide",
  iban_invalid: "IBAN invalides",
  negatives: "valeurs négatives",
};

export function typeLabel(code: string): string {
  return TYPE_FR[code] ?? code;
}

export function columnIssuesLabel(issues: Record<string, unknown>): string {
  return Object.keys(issues)
    .map((k) => COLUMN_ISSUE_FR[k] ?? k)
    .join(", ");
}
