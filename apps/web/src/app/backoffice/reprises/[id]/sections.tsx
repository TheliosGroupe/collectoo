import { ActionForm } from "@/components/action-form";
import { Badge, InfoNote, Section, Stats, dangerButtonClass, inlineButtonClass, inputClass } from "@/components/ui";
import { formatPct, mappingField } from "@/lib/boarding/forms";
import { columnIssuesLabel, readProfile, typeLabel, type FileProfile } from "@/lib/boarding/profile";
import { issueLabel, statusLabel } from "@/lib/boarding/status";
import { targetGroups, targetLabel } from "@/lib/boarding/targets";
import { formatMoneyFr } from "@/lib/money";
import { abandonBatch, approveMapping, commitBatch, confirmBatch, rollbackBatch } from "./actions";

// --- Types of the JSON written by the worker (worker/src/collectoo_worker/boarding) ---------------

export type FileRow = {
  id: string;
  file_name: string;
  format: string;
  status: string;
  row_count: number | null;
  profile: unknown;
  error: string | null;
  duplicate_of_file_id: string | null;
};
export type ProposalRow = {
  id: string;
  file_id: string;
  source_column: string;
  target: string | null;
  confidence: number;
  rationale: string;
  needs_review: boolean;
  origin: string;
  status: string;
};
export type IssueRow = {
  id: number;
  file_id: string;
  row_number: number | null;
  source_column: string | null;
  code: string;
  severity: "blocking" | "warning";
  message: string;
  raw_value: string | null;
};
type CurrencyTotals = { rows: number; total_minor: string; paid_minor: string; outstanding_minor: string };
export type DqReport = {
  files: { file_id: string; name: string; rows: number; issues: Record<string, { severity: string; count: number }> }[];
  totals: { rows: number; blocking: number; warnings: number };
  duplicates: number;
  contactability: { rows: number; email_pct: number; phone_pct: number; postal_pct: number; any_pct: number };
  claim_types: Record<string, number>;
  legal_regimes: Record<string, number>;
  reconciliation: {
    status: "matched" | "mismatch" | "no_control_totals";
    control: { rows?: number | null; total_minor?: number | null } | null;
    computed: { rows: number; file_rows?: number; currencies?: Record<string, CurrencyTotals> };
    difference_rows?: number;
    currency_mismatch?: string[];
  };
  staging?: {
    already_boarded_accounts_skipped: number;
    entities: Record<string, { rows: number }>;
    opening?: OpeningTotals;
    skipped?: OpeningTotals;
  };
  documents?: { linked: number; unmatched: string[]; unsupported: string[] };
};
/** Opening balances per currency, amounts as text (dq_report.staging.opening, opening_plan). */
export type OpeningTotals = {
  currencies: Record<
    string,
    { accounts: number; accounts_without_balance: number; outstanding_minor: string; components: Record<string, string> }
  >;
};

const COMPONENT_FR: Record<string, string> = {
  principal: "Principal",
  accrued_interest: "Intérêts échus déclarés",
  other_balances: "Autres sommes déclarées",
  balancing_line: "Écart au solde légal",
};

function OpeningTable({ totals, testId }: { totals: OpeningTotals; testId: string }) {
  return (
    <div className="flex flex-col gap-3" data-testid={testId}>
      {Object.entries(totals.currencies).map(([currency, t]) => (
        <div key={currency}>
          <Stats
            items={[
              { label: "Encours total", value: money(t.outstanding_minor, currency), testId: `${testId}-total` },
              { label: "Comptes avec solde", value: count(t.accounts) },
              { label: "Comptes soldés", value: count(t.accounts_without_balance) },
              { label: "Devise", value: currency },
            ]}
          />
          <ul className="mt-2 text-sm">
            {Object.entries(t.components).map(([c, v]) => (
              <li key={c}>
                {COMPONENT_FR[c] ?? c} : {money(v, currency)}
              </li>
            ))}
          </ul>
        </div>
      ))}
    </div>
  );
}

/**
 * Accounts of the tape already in the portfolio are not boarded again: the quality report's
 * outstanding includes them, the opening balances do not (outstanding = opening + this).
 */
function SkippedNote({ report }: { report: DqReport | null }) {
  const skipped = Object.entries(report?.staging?.skipped?.currencies ?? {}).filter(
    ([, t]) => t.accounts + t.accounts_without_balance > 0,
  );
  if (skipped.length === 0) return null;
  return (
    <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400" data-testid="opening-skipped">
      Non repris car déjà présents dans le portefeuille (inclus dans l&apos;encours du contrôle qualité) :{" "}
      {skipped
        .map(([currency, t]) => `${count(t.accounts + t.accounts_without_balance)} compte(s), ${money(t.outstanding_minor, currency)}`)
        .join(" ; ")}
      .
    </p>
  );
}

/** Amounts read with ->> (text): integer minor units, never JS numbers. */
export type Money = {
  total_minor: string | null;
  paid_minor: string | null;
  outstanding_minor: string | null;
  control_minor: string | null;
  difference_minor: string | null;
};

const money = (minor: string | null, currency = "EUR") =>
  minor === null ? "—" : formatMoneyFr({ minor: BigInt(minor), currency });
const count = (n: number) => n.toLocaleString("fr-FR");

const CLAIM_TYPE_FR: Record<string, string> = {
  b2b_invoice: "Factures entre professionnels",
  b2c_invoice: "Factures particuliers",
  rent: "Loyers",
  private_loan: "Prêts entre particuliers",
  judgment_debt: "Créances jugées",
  consumer_instalment_loan: "Crédits à la consommation",
  revolving_credit: "Crédits renouvelables",
  overdraft: "Découverts",
  bnpl: "Paiements fractionnés",
  consumer_mortgage: "Crédits immobiliers",
  professional_loan: "Prêts professionnels",
};

/** Steps before commit, where a batch can still be abandoned (after commit: rollback). */
const ABANDONABLE = new Set([
  "draft",
  "uploaded",
  "profiled",
  "mapping_proposed",
  "mapping_approved",
  "transformed",
  "validated",
  "needs_fix",
  "staged",
]);

// --- Files and profiles ------------------------------------------------------------------------------

function profileSummary(p: FileProfile): string {
  switch (p.kind) {
    case "table":
      return `${p.sheet ? `feuille « ${p.sheet} » · ` : ""}${p.table.columns.length} colonnes${
        p.table.duplicate_rows ? ` · ${count(p.table.duplicate_rows)} doublons` : ""
      }`;
    case "empty_workbook":
      return "classeur sans données";
    case "documents":
      return "pièces jointes, rattachées après l'intégration";
    case "needs_layout":
      return "largeur fixe : description des colonnes nécessaire";
    default:
      return "";
  }
}

export function FilesSection({ files }: { files: FileRow[] }) {
  return (
    <Section title="Fichiers" testId="files">
      <ul className="flex flex-col gap-3">
        {files.map((f) => {
          const profile = readProfile(f.profile);
          const summary = profileSummary(profile);
          return (
            <li key={f.id} className="rounded-md border border-zinc-200 dark:border-zinc-800">
              <details>
                <summary className="cursor-pointer p-3">
                  <span className="inline-flex flex-wrap items-center gap-x-3 gap-y-1 align-middle">
                    <span className="font-medium break-all">{f.file_name}</span>
                    <span className="text-sm text-zinc-600 dark:text-zinc-400">
                      {f.format.toUpperCase()}
                      {profile.kind === "table" && profile.sheet
                        ? ` · ${count(profile.table.row_count)} lignes`
                        : f.row_count !== null
                          ? ` · ${count(f.row_count)} lignes`
                          : ""}
                      {summary ? ` · ${summary}` : ""}
                    </span>
                    {f.duplicate_of_file_id ? <Badge tone="action">Déjà reçu</Badge> : null}
                    {f.status === "failed" ? <Badge tone="error">Erreur</Badge> : null}
                  </span>
                </summary>
                {f.error ? <p className="px-3 pb-3 font-mono text-xs break-all text-red-800 dark:text-red-200">{f.error}</p> : null}
                {profile.kind === "table" ? (
                  <div className="overflow-x-auto border-t border-zinc-200 dark:border-zinc-800">
                    <table className="w-full min-w-[560px] text-left text-sm">
                      <caption className="sr-only">Profil des colonnes de {f.file_name}</caption>
                      <thead className="text-xs text-zinc-600 dark:text-zinc-400">
                        <tr>
                          <th className="p-2">Colonne</th>
                          <th className="p-2">Type détecté</th>
                          <th className="p-2">Vides</th>
                          <th className="p-2">Distinctes</th>
                          <th className="p-2">Alertes</th>
                        </tr>
                      </thead>
                      <tbody>
                        {profile.table.columns.map((c) => (
                          <tr key={c.name} className="border-t border-zinc-100 dark:border-zinc-900">
                            <td className="p-2 font-mono text-xs">{c.name}</td>
                            <td className="p-2">{typeLabel(c.type_guess)}</td>
                            <td className="p-2 tabular-nums">{formatPct(c.null_pct)}</td>
                            <td className="p-2 tabular-nums">{count(c.distinct)}</td>
                            <td className="p-2 text-xs">{columnIssuesLabel(c.issues) || "—"}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                ) : null}
              </details>
            </li>
          );
        })}
      </ul>
    </Section>
  );
}

// --- Mapping review ------------------------------------------------------------------------------------

function TargetSelect({ name, value, column }: { name: string; value: string | null; column: string }) {
  return (
    <select name={name} defaultValue={value ?? ""} className={inputClass} aria-label={`Cible de la colonne ${column}`}>
      <option value="">Non repris</option>
      {targetGroups().map((g) => (
        <optgroup key={g.label} label={g.label}>
          {g.targets.map((t) => (
            <option key={t.id} value={t.id}>
              {targetLabel(t.id)}
            </option>
          ))}
        </optgroup>
      ))}
    </select>
  );
}

export function MappingSection({
  batchId,
  editable,
  proposals,
  files,
}: {
  batchId: string;
  editable: boolean;
  proposals: ProposalRow[];
  files: FileRow[];
}) {
  const profiles = new Map(files.map((f) => [f.id, readProfile(f.profile)]));
  const toReview = proposals.filter((p) => p.needs_review).length;
  const examples = new Map<string, string | undefined>();
  for (const f of files) {
    const p = profiles.get(f.id);
    if (p?.kind !== "table") continue;
    for (const c of p.table.columns) examples.set(`${f.id}:${c.name}`, c.top_values?.[0]?.value);
  }
  // A tabular file that cannot be read as a table would be left out: never approve around it.
  const unreadable = files.filter((f) => {
    const kind = profiles.get(f.id)?.kind;
    return kind === "needs_layout" || kind === "empty_workbook";
  });
  const content = files
    .filter((f) => proposals.some((p) => p.file_id === f.id))
    .map((f) => (
      <div key={f.id} className="flex flex-col gap-2">
        {files.length > 1 ? <h3 className="text-sm font-medium break-all">{f.file_name}</h3> : null}
        <ul className="flex flex-col divide-y divide-zinc-100 dark:divide-zinc-900">
          {proposals
            .filter((p) => p.file_id === f.id)
            .map((p) => (
              <li
                key={p.id}
                className={`grid gap-2 py-3 md:grid-cols-[1fr_1.4fr_auto] md:items-center ${p.needs_review && editable ? "rounded-md bg-amber-50 px-2 dark:bg-amber-950/40" : ""}`}
                data-testid="proposal"
              >
                <div className="min-w-0">
                  <p className="font-mono text-sm break-all">{p.source_column}</p>
                  {examples.get(`${f.id}:${p.source_column}`) ? (
                    <p className="truncate text-xs text-zinc-600 dark:text-zinc-400">
                      ex. {examples.get(`${f.id}:${p.source_column}`)}
                    </p>
                  ) : null}
                </div>
                <div className="min-w-0">
                  {editable ? (
                    <TargetSelect name={mappingField(p.file_id, p.source_column)} value={p.target} column={p.source_column} />
                  ) : (
                    <p className="text-sm">
                      {targetLabel(p.target)}
                      {p.status === "overridden" ? <span className="text-zinc-500"> (corrigé)</span> : null}
                    </p>
                  )}
                  <p className="mt-1 text-xs text-zinc-600 dark:text-zinc-400">
                    <span className="sr-only">Justification automatique : </span>
                    {p.rationale}
                  </p>
                </div>
                <div className="flex items-center gap-2 md:justify-end">
                  <Badge tone={p.confidence >= 0.9 ? "ok" : p.confidence >= 0.7 ? "neutral" : "action"}>
                    <span className="sr-only">Confiance </span>
                    {Math.round(p.confidence * 100)} %
                  </Badge>
                  {p.needs_review && editable ? <Badge tone="action">À vérifier</Badge> : null}
                </div>
              </li>
            ))}
        </ul>
      </div>
    ));

  if (editable && unreadable.length > 0) {
    return (
      <Section title="Mapping des colonnes" testId="mapping">
        <InfoNote>
          {unreadable.map((f) => f.file_name).join(", ")} : pas de tableau lisible (fichier à largeur fixe dont la
          description des colonnes n&apos;est pas encore gérée par l&apos;interface, ou classeur vide). Ces données ne seraient
          pas reprises : abandonnez ce lot et déposez-les en CSV ou Excel.
        </InfoNote>
      </Section>
    );
  }
  return (
    <Section title="Mapping des colonnes" testId="mapping">
      {editable ? (
        <ActionForm
          action={approveMapping}
          submitLabel="Valider le mapping"
          pendingLabel="Validation…"
          buttonClassName={inlineButtonClass}
          className="flex flex-col gap-4"
        >
          <input type="hidden" name="batch_id" value={batchId} />
          <InfoNote>
            {proposals.length === 0
              ? "Ce lot ne contient que des pièces jointes : validez pour les rattacher aux comptes du portefeuille."
              : toReview > 0
                ? `Proposition automatique : vérifiez surtout les ${toReview} colonne(s) surlignée(s), corrigez la cible si besoin, puis validez. Le mapping validé est réutilisé pour les prochains fichiers de même format.`
                : "Proposition automatique : relisez les cibles, corrigez-les si besoin, puis validez. Le mapping validé est réutilisé pour les prochains fichiers de même format."}
          </InfoNote>
          {content}
        </ActionForm>
      ) : (
        <div className="flex flex-col gap-4">{content}</div>
      )}
    </Section>
  );
}

// --- Data-quality report -------------------------------------------------------------------------------

function Reconciliation({ report, amounts }: { report: DqReport; amounts: Money }) {
  const rec = report.reconciliation;
  const currencies = Object.entries(rec.computed.currencies ?? {});
  const single = currencies.length <= 1;
  const currency = currencies[0]?.[0] ?? "EUR";
  const control = rec.control;
  const fileRows = rec.computed.file_rows ?? rec.computed.rows;
  return (
    <div>
      <h3 className="mb-2 text-sm font-medium">Rapprochement avec le cédant</h3>
      {single ? (
        <Stats
          items={[
            { label: "Montant des pièces", value: money(amounts.total_minor, currency), testId: "dq-total" },
            { label: "Déjà payé (cédant)", value: money(amounts.paid_minor, currency) },
            { label: "Encours restant dû", value: money(amounts.outstanding_minor, currency), testId: "dq-outstanding" },
            {
              label: "Encours annoncé",
              value: control?.total_minor == null ? "Non fourni" : money(amounts.control_minor, "EUR"),
            },
          ]}
        />
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[480px] text-left text-sm" data-testid="dq-currencies">
            <caption className="sr-only">Montants par devise</caption>
            <thead className="text-xs text-zinc-600 dark:text-zinc-400">
              <tr>
                <th className="p-2">Devise</th>
                <th className="p-2">Lignes</th>
                <th className="p-2">Montant des pièces</th>
                <th className="p-2">Encours restant dû</th>
              </tr>
            </thead>
            <tbody>
              {currencies.map(([code, t]) => (
                <tr key={code} className="border-t border-zinc-100 dark:border-zinc-900">
                  <td className="p-2">{code}</td>
                  <td className="p-2 tabular-nums">{count(t.rows)}</td>
                  <td className="p-2 tabular-nums">{money(t.total_minor, code)}</td>
                  <td className="p-2 tabular-nums">{money(t.outstanding_minor, code)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="mt-2 text-sm">
        Lignes du fichier : {count(fileRows)}
        {control?.rows != null ? ` · annoncées : ${count(control.rows)}` : ""}
      </p>
      <p className="mt-2 flex flex-wrap gap-2 text-sm" data-testid="dq-reconciliation">
        {rec.status === "matched" ? (
          <Badge tone="ok">
            {control?.total_minor != null ? "Encours concordant au centime" : "Nombre de lignes concordant"}
            {control?.total_minor != null && control?.rows != null ? ", lignes concordantes" : ""}
          </Badge>
        ) : rec.status === "mismatch" ? (
          <>
            {rec.currency_mismatch ? (
              <Badge tone="error">
                {rec.currency_mismatch.length > 1
                  ? "Plusieurs devises"
                  : `Montants en ${rec.currency_mismatch[0]}`}{" "}
                : pas de rapprochement possible avec un total en euros
              </Badge>
            ) : amounts.difference_minor !== null && amounts.difference_minor !== "0" ? (
              <Badge tone="error">Écart d&apos;encours de {money(amounts.difference_minor, "EUR")} (fichier − annoncé)</Badge>
            ) : null}
            {rec.difference_rows ? (
              <Badge tone="error">
                {count(Math.abs(rec.difference_rows))} ligne(s) {rec.difference_rows > 0 ? "de plus" : "de moins"} que
                l&apos;annonce
              </Badge>
            ) : null}
          </>
        ) : (
          <Badge tone="neutral">Pas de totaux cédant : rapprochement non effectué</Badge>
        )}
      </p>
    </div>
  );
}

export function QualitySection({
  report,
  money: amounts,
  issues,
  fileNames,
}: {
  report: DqReport;
  money: Money;
  issues: IssueRow[];
  fileNames: Record<string, string>;
}) {
  const byCode = new Map<string, { severity: string; count: number }>();
  for (const f of report.files) {
    for (const [code, v] of Object.entries(f.issues)) {
      if (v.count === 0) continue;
      const prev = byCode.get(code);
      byCode.set(code, { severity: v.severity, count: (prev?.count ?? 0) + v.count });
    }
  }
  return (
    <Section title="Contrôle qualité" testId="quality">
      <div className="flex flex-col gap-4">
        <Stats
          items={[
            { label: "Lignes", value: count(report.totals.rows), testId: "dq-rows" },
            { label: "Anomalies bloquantes", value: count(report.totals.blocking), testId: "dq-blocking" },
            { label: "Avertissements", value: count(report.totals.warnings) },
            { label: "Lignes en double", value: count(report.duplicates) },
          ]}
        />
        <Reconciliation report={report} amounts={amounts} />
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <h3 className="mb-2 text-sm font-medium">Joignabilité</h3>
            <ul className="text-sm">
              <li>E-mail : {formatPct(report.contactability.email_pct)}</li>
              <li>Téléphone : {formatPct(report.contactability.phone_pct)}</li>
              <li>Adresse postale : {formatPct(report.contactability.postal_pct)}</li>
              <li>Au moins un moyen : {formatPct(report.contactability.any_pct)}</li>
            </ul>
          </div>
          <div>
            <h3 className="mb-2 text-sm font-medium">Types de créances</h3>
            <ul className="text-sm">
              {Object.entries(report.claim_types).map(([k, n]) => (
                <li key={k}>
                  {CLAIM_TYPE_FR[k] ?? k} : {count(n)}
                </li>
              ))}
            </ul>
          </div>
        </div>
        {byCode.size > 0 ? (
          <div>
            <h3 className="mb-2 text-sm font-medium">Anomalies par type</h3>
            <ul className="flex flex-col gap-1 text-sm" data-testid="dq-issues">
              {[...byCode.entries()]
                .sort((a, b) => (a[1].severity === b[1].severity ? b[1].count - a[1].count : a[1].severity === "blocking" ? -1 : 1))
                .map(([code, v]) => (
                  <li key={code} className="flex items-center gap-2">
                    <Badge tone={v.severity === "blocking" ? "error" : "action"}>
                      {v.severity === "blocking" ? "Bloquant" : "Avertissement"}
                    </Badge>
                    {issueLabel(code)} : {count(v.count)}
                  </li>
                ))}
            </ul>
          </div>
        ) : null}
        {issues.length > 0 ? (
          <details>
            <summary className="cursor-pointer text-sm font-medium">Détail des premières anomalies ({issues.length})</summary>
            <div className="mt-2 overflow-x-auto">
              <table className="w-full min-w-[560px] text-left text-sm">
                <thead className="text-xs text-zinc-600 dark:text-zinc-400">
                  <tr>
                    <th className="p-2">Fichier</th>
                    <th className="p-2">N° de ligne de données</th>
                    <th className="p-2">Colonne</th>
                    <th className="p-2">Anomalie</th>
                    <th className="p-2">Valeur</th>
                  </tr>
                </thead>
                <tbody>
                  {issues.map((i) => (
                    <tr key={i.id} className="border-t border-zinc-100 dark:border-zinc-900">
                      <td className="p-2 break-all">{fileNames[i.file_id] ?? ""}</td>
                      <td className="p-2 tabular-nums">{i.row_number ?? "—"}</td>
                      <td className="p-2 font-mono text-xs">{i.source_column ?? "—"}</td>
                      <td className="p-2">{issueLabel(i.code)}</td>
                      <td className="p-2 font-mono text-xs break-all">{i.raw_value ?? ""}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="mt-2 text-xs text-zinc-600 dark:text-zinc-400">
              N° 1 = première ligne après l&apos;en-tête (ligne 2 du fichier CSV). Dans un classeur Excel, les lignes vides ne
              sont pas comptées.
            </p>
          </details>
        ) : null}
        {report.documents ? (
          <p className="text-sm" data-testid="dq-documents">
            Pièces jointes : {count(report.documents.linked)} rattachées
            {report.documents.unmatched.length ? `, ${report.documents.unmatched.length} sans référence reconnue` : ""}
            {report.documents.unsupported.length ? `, ${report.documents.unsupported.length} format non pris en charge` : ""}.
          </p>
        ) : null}
      </div>
    </Section>
  );
}

// --- Commit, confirmation, rollback, abandon ------------------------------------------------------------

export function IntegrationSection({
  batchId,
  status,
  report,
  openingPlan,
  openingSummary,
}: {
  batchId: string;
  status: string;
  report: DqReport | null;
  openingPlan: OpeningTotals | null;
  openingSummary: { entries: number; totals: OpeningTotals } | null;
}) {
  const hidden = <input type="hidden" name="batch_id" value={batchId} />;
  const staged = report?.staging?.entities ?? {};
  if (status === "needs_fix") {
    return (
      <Section title="Intégration">
        <InfoNote>
          Des anomalies bloquantes empêchent l&apos;intégration. Faites corriger le fichier par le cédant, abandonnez ce lot et
          déposez le fichier corrigé dans un nouveau lot.
        </InfoNote>
      </Section>
    );
  }
  if (status === "staged") {
    const mismatch = report?.reconciliation.status === "mismatch";
    return (
      <Section title="Intégration" testId="integration">
        <p className="mb-3 text-sm">
          Prêt à intégrer : {count(staged.account?.rows ?? 0)} comptes, {count(staged.party?.rows ?? 0)} débiteurs,{" "}
          {count(staged.claim_item?.rows ?? 0)} pièces.
          {report?.staging?.already_boarded_accounts_skipped
            ? ` ${count(report.staging.already_boarded_accounts_skipped)} compte(s) déjà présents ignorés.`
            : ""}
        </p>
        <ActionForm
          action={commitBatch}
          submitLabel="Intégrer le lot"
          pendingLabel="Intégration…"
          buttonClassName={inlineButtonClass}
          className="flex flex-col gap-3"
        >
          {hidden}
          <label className="flex flex-col gap-1 text-sm">
            {mismatch ? "Motif (obligatoire : le rapprochement avec le cédant n'est pas concordant)" : "Commentaire (facultatif)"}
            <input name="reason" required={mismatch} className={inputClass} />
          </label>
        </ActionForm>
      </Section>
    );
  }
  if (status === "committing") {
    return (
      <Section title="Intégration" testId="integration">
        <InfoNote>Intégration en cours : création des comptes, des pièces et du plan des soldes d&apos;ouverture… la page se met à jour seule.</InfoNote>
      </Section>
    );
  }
  if (status === "committed") {
    return (
      <Section title="Intégration" testId="integration">
        {openingPlan ? (
          <>
            <InfoNote>
              Le lot est intégré mais aucun débiteur ne sera contacté avant confirmation par un responsable (mandat actif
              requis). Avant confirmation, l&apos;intégration peut être annulée. La confirmation comptabilise les soldes
              d&apos;ouverture ci-dessous, à la date d&apos;arrêté.
            </InfoNote>
            <div className="mt-4">
              <h3 className="mb-2 text-sm font-medium">Soldes d&apos;ouverture prévus</h3>
              <OpeningTable totals={openingPlan} testId="opening-plan" />
              <SkippedNote report={report} />
            </div>
          </>
        ) : (
          <InfoNote>
            Ce lot a été intégré avant la comptabilisation des soldes d&apos;ouverture : il ne peut pas être confirmé.
            Annulez l&apos;intégration, puis déposez à nouveau le fichier dans un nouveau lot.
          </InfoNote>
        )}
        <div className="mt-4 flex flex-col gap-4 sm:flex-row sm:items-end">
          {openingPlan ? (
            <ActionForm action={confirmBatch} submitLabel="Confirmer le lot" pendingLabel="Confirmation…" buttonClassName={inlineButtonClass}>
              {hidden}
            </ActionForm>
          ) : null}
          <ActionForm
            action={rollbackBatch}
            submitLabel="Annuler l'intégration"
            pendingLabel="Annulation…"
            buttonClassName={dangerButtonClass}
            className="flex flex-1 flex-col gap-2"
          >
            {hidden}
            <label className="flex flex-col gap-1 text-sm">
              Motif d&apos;annulation
              <input name="reason" required className={inputClass} />
            </label>
          </ActionForm>
        </div>
      </Section>
    );
  }
  if (status === "confirming") {
    return (
      <Section title="Intégration" testId="integration">
        <InfoNote>Confirmation en cours : comptabilisation des soldes d&apos;ouverture… la page se met à jour seule.</InfoNote>
      </Section>
    );
  }
  if (status === "confirmed") {
    return (
      <Section title="Intégration" testId="integration">
        <p className="text-sm">
          Lot confirmé : les comptes attendent la première lettre au débiteur (art. R124-4 CPCE), seule action possible à ce
          stade.
        </p>
        {openingSummary ? (
          <div className="mt-4">
            <h3 className="mb-2 text-sm font-medium">
              Soldes d&apos;ouverture comptabilisés ({count(openingSummary.entries)} écritures)
            </h3>
            <OpeningTable totals={openingSummary.totals} testId="opening-summary" />
            <SkippedNote report={report} />
          </div>
        ) : null}
      </Section>
    );
  }
  return null;
}

export function AbandonSection({ batchId, status }: { batchId: string; status: string }) {
  if (!ABANDONABLE.has(status)) return null;
  return (
    <details className="rounded-lg border border-zinc-200 p-4 dark:border-zinc-800" data-testid="abandon">
      <summary className="cursor-pointer font-medium">Abandonner ce lot</summary>
      <ActionForm
        action={abandonBatch}
        submitLabel="Abandonner le lot"
        pendingLabel="Abandon…"
        buttonClassName={dangerButtonClass}
        className="mt-3 flex flex-col gap-2"
      >
        <input type="hidden" name="batch_id" value={batchId} />
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          Rien n&apos;a été intégré : le lot est clos et ses données préparées sont supprimées. Les fichiers déposés restent stockés.
        </p>
        <label className="flex flex-col gap-1 text-sm">
          Motif de l&apos;abandon
          <input name="reason" required className={inputClass} />
        </label>
      </ActionForm>
    </details>
  );
}

// --- History ---------------------------------------------------------------------------------------------

/**
 * The reason worth showing: a motif typed by staff (abandon, rollback, commit despite a mismatch)
 * or why a confirmation came back. Step names recorded by the system are not repeated.
 */
function historyReason(e: { to_status: string; reason: string | null }): string | null {
  if (!e.reason) return null;
  // Back to staged (failed commit), committed (motif, or failed confirmation), abandon, rollback.
  if (!["abandoned", "rolled_back", "committed", "staged"].includes(e.to_status)) return null;
  return ["committed", "rows staged"].includes(e.reason) ? null : e.reason;
}

export function HistorySection({
  events,
}: {
  events: { id: number; to_status: string; reason: string | null; actor_label: string | null; at: string }[];
}) {
  return (
    <Section title="Historique" testId="history">
      <ol className="flex flex-col gap-1 text-sm">
        {events.map((e) => (
          <li key={e.id} className="flex flex-wrap gap-x-2">
            <span className="tabular-nums text-zinc-600 dark:text-zinc-400">
              {new Date(e.at).toLocaleString("fr-FR", { timeZone: "Europe/Paris", dateStyle: "short", timeStyle: "medium" })}
            </span>
            <span>{statusLabel(e.to_status)}</span>
            {e.actor_label ? <span className="text-zinc-500">({e.actor_label === "worker:boarding" ? "automatique" : e.actor_label})</span> : null}
            {historyReason(e) ? <span className="w-full text-zinc-600 sm:w-auto dark:text-zinc-400">— {historyReason(e)}</span> : null}
          </li>
        ))}
      </ol>
    </Section>
  );
}
