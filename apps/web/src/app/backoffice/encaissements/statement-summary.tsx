import { Badge, ErrorNote, InfoNote, Stats } from "@/components/ui";
import { frenchDate } from "@/lib/payments/bank-accounts";
import {
  type BankCheck,
  type Warning,
  bankCheckText,
  importErrorText,
  money,
  statementStatus,
  warningText,
} from "@/lib/payments/statements";

/** What the import did (bank_statement.counts); amounts are text. */
export type Counts = {
  lines: number;
  new_lines: number;
  known_lines: number;
  skipped_not_booked: number;
  payments: { count: number; minor: string };
  unposted: { lines: number; minor: string };
  cash_in: { date: string; entry_id: string; minor: string }[];
  suspected_duplicates: number;
  batch_unsplit: number;
};

export type StatementRow = {
  id: string;
  file_name: string;
  format: string;
  currency: string;
  status: string;
  from_date: string | null;
  to_date: string | null;
  created_at: string;
  counts: Counts | null;
  warnings: Warning[];
  bank_check: BankCheck | null;
  error_code: string | null;
  error: string | null;
  bank_account: { label: string } | null;
};

export const STATEMENT_COLUMNS =
  "id, file_name, format, currency, status, from_date, to_date, created_at, counts, warnings, bank_check, error_code," +
  " error, bank_account:bank_account!bank_statement_bank_fk(label)";

/** One statement: status, period, what was booked, the bank check and the warnings. */
export function StatementSummary({ s }: { s: StatementRow }) {
  const status = statementStatus(s.status);
  const check = s.status === "imported" ? bankCheckText(s.bank_check, s.currency) : null;
  const c = s.counts;
  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2 text-sm text-zinc-600 dark:text-zinc-400">
        <Badge tone={status.tone} testId="statement-status">
          {status.label}
        </Badge>
        <span>
          {s.bank_account?.label} · {s.format === "csv" ? "CSV" : "CAMT.053"}
        </span>
        {s.from_date && s.to_date ? (
          <span>
            · du {frenchDate(s.from_date)} au {frenchDate(s.to_date)}
          </span>
        ) : null}
      </div>
      {c ? (
        <Stats
          items={[
            { label: "Opérations lues", value: c.lines, testId: "count-lines" },
            { label: "Déjà importées", value: c.known_lines, testId: "count-known" },
            {
              label: "Encaissements comptabilisés",
              value: `${c.payments.count} · ${money(c.payments.minor, s.currency)}`,
              testId: "count-payments",
            },
            { label: "À classer ou retenues", value: c.unposted.lines, testId: "count-unposted" },
          ]}
        />
      ) : null}
      {check ? (
        <p className="text-sm" data-testid="bank-check">
          <Badge tone={check.tone}>{check.tone === "error" ? "Écart" : "Banque"}</Badge> {check.text}
        </p>
      ) : null}
      {c && c.suspected_duplicates > 0 ? (
        <InfoNote>
          {c.suspected_duplicates} opération(s) ressemblent à des opérations déjà importées (même jour, même montant, libellé
          proche) : elles sont retenues, ni comptabilisées ni affectées, en attendant une décision.
        </InfoNote>
      ) : null}
      {s.warnings.map((w) => (
        <InfoNote key={`${w.code}-${w.expected_minor ?? ""}-${w.seq ?? ""}`}>{warningText(w, s.currency)}</InfoNote>
      ))}
      {s.status === "rejected" || s.status === "failed" ? (
        <ErrorNote>{importErrorText(s.error_code, s.error)}</ErrorNote>
      ) : null}
    </div>
  );
}
