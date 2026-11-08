import { Badge, InfoNote, Section, Stats, dangerButtonClass, inlineButtonClass, inputClass } from "@/components/ui";
import { mappingField } from "@/lib/boarding/forms";
import { issueLabel, statusLabel } from "@/lib/boarding/status";
import { targetGroups, targetLabel } from "@/lib/boarding/targets";
import { formatMoneyFr } from "@/lib/money";
import { approveMapping, commitBatch, confirmBatch, rollbackBatch } from "./actions";

// --- Types of the JSON written by the worker (worker/src/collectoo_worker/boarding) ---------------

type ProfileColumn = {
  name: string;
  non_null: number;
  null_pct: number;
  distinct: number;
  type_guess: string;
  issues: Record<string, unknown>;
  top_values?: { value: string; count: number }[];
};
export type FileRow = {
  id: string;
  file_name: string;
  format: string;
  status: string;
  row_count: number | null;
  profile: { row_count: number; duplicate_rows: number; columns: ProfileColumn[] } | null;
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
export type DqReport = {
  files: { file_id: string; name: string; rows: number; issues: Record<string, { severity: string; count: number }> }[];
  totals: { rows: number; blocking: number; warnings: number };
  duplicates: number;
  contactability: { rows: number; email_pct: number; phone_pct: number; postal_pct: number; any_pct: number };
  claim_types: Record<string, number>;
  legal_regimes: Record<string, number>;
  reconciliation: { status: "matched" | "mismatch" | "no_control_totals"; control: { rows?: number } | null };
  staging?: { already_boarded_accounts_skipped: number; entities: Record<string, { rows: number }> };
  documents?: { linked: number; unmatched: string[]; unsupported: string[] };
};
type Money = {
  total_minor: string | null;
  paid_minor: string | null;
  outstanding_minor: string | null;
  control_minor: string | null;
  difference_minor: string | null;
};

const pct = (ratio: number) => `${Math.round(ratio * 1000) / 10} %`;
const eur = (minor: string | null) => (minor === null ? "—" : formatMoneyFr({ minor: BigInt(minor), currency: "EUR" }));
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

// --- Files and profiles ------------------------------------------------------------------------------

export function FilesSection({ files }: { files: FileRow[] }) {
  return (
    <Section title="Fichiers" testId="files">
      <ul className="flex flex-col gap-3">
        {files.map((f) => (
          <li key={f.id} className="rounded-md border border-zinc-200 dark:border-zinc-800">
            <details>
              <summary className="flex cursor-pointer flex-wrap items-center gap-x-3 gap-y-1 p-3">
                <span className="font-medium break-all">{f.file_name}</span>
                <span className="text-sm text-zinc-600 dark:text-zinc-400">
                  {f.format.toUpperCase()}
                  {f.row_count !== null ? ` · ${count(f.row_count)} lignes` : ""}
                  {f.profile ? ` · ${f.profile.columns.length} colonnes` : ""}
                  {f.profile?.duplicate_rows ? ` · ${count(f.profile.duplicate_rows)} doublons` : ""}
                </span>
                {f.duplicate_of_file_id ? <Badge tone="action">Déjà reçu</Badge> : null}
                {f.error ? <Badge tone="error">Erreur</Badge> : null}
              </summary>
              {f.error ? <p className="px-3 pb-3 text-sm text-red-800 dark:text-red-200">{f.error}</p> : null}
              {f.profile ? (
                <div className="overflow-x-auto border-t border-zinc-200 dark:border-zinc-800">
                  <table className="w-full min-w-[560px] text-left text-sm">
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
                      {f.profile.columns.map((c) => (
                        <tr key={c.name} className="border-t border-zinc-100 dark:border-zinc-900">
                          <td className="p-2 font-mono text-xs">{c.name}</td>
                          <td className="p-2">{c.type_guess}</td>
                          <td className="p-2 tabular-nums">{pct(c.null_pct)}</td>
                          <td className="p-2 tabular-nums">{count(c.distinct)}</td>
                          <td className="p-2 text-xs">{Object.keys(c.issues).join(", ") || "—"}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              ) : null}
            </details>
          </li>
        ))}
      </ul>
    </Section>
  );
}

// --- Mapping review ------------------------------------------------------------------------------------

function TargetSelect({ name, value }: { name: string; value: string | null }) {
  return (
    <select name={name} defaultValue={value ?? ""} className={`${inputClass} text-sm`} aria-label="Cible">
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
  const toReview = proposals.filter((p) => p.needs_review).length;
  const examples = new Map(
    files.flatMap((f) => (f.profile?.columns ?? []).map((c) => [`${f.id}:${c.name}`, c.top_values?.[0]?.value])),
  );
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
                    <TargetSelect name={mappingField(p.file_id, p.source_column)} value={p.target} />
                  ) : (
                    <p className="text-sm">
                      {targetLabel(p.target)}
                      {p.status === "overridden" ? <span className="text-zinc-500"> (corrigé)</span> : null}
                    </p>
                  )}
                  <p className="mt-1 text-xs text-zinc-600 dark:text-zinc-400">{p.rationale}</p>
                </div>
                <div className="flex items-center gap-2 md:justify-end">
                  <Badge tone={p.confidence >= 0.9 ? "ok" : p.confidence >= 0.7 ? "neutral" : "action"}>
                    {Math.round(p.confidence * 100)} %
                  </Badge>
                  {p.needs_review && editable ? <Badge tone="action">À vérifier</Badge> : null}
                </div>
              </li>
            ))}
        </ul>
      </div>
    ));

  return (
    <Section title="Mapping des colonnes" testId="mapping">
      {editable ? (
        <form action={approveMapping} className="flex flex-col gap-4">
          <input type="hidden" name="batch_id" value={batchId} />
          <InfoNote>
            {toReview > 0
              ? `Proposition automatique : vérifiez surtout les ${toReview} colonne(s) surlignée(s), corrigez la cible si besoin, puis validez.`
              : "Proposition automatique : relisez les cibles, corrigez-les si besoin, puis validez."}{" "}
            Le mapping validé est réutilisé pour les prochains fichiers de même format.
          </InfoNote>
          {content}
          <button type="submit" className={inlineButtonClass}>
            Valider le mapping
          </button>
        </form>
      ) : (
        <div className="flex flex-col gap-4">{content}</div>
      )}
    </Section>
  );
}

// --- Data-quality report -------------------------------------------------------------------------------

export function QualitySection({
  report,
  money,
  issues,
  fileNames,
}: {
  report: DqReport;
  money: Money;
  issues: IssueRow[];
  fileNames: Record<string, string>;
}) {
  const rec = report.reconciliation;
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
        <div>
          <h3 className="mb-2 text-sm font-medium">Rapprochement des montants</h3>
          <Stats
            items={[
              { label: "Montant calculé", value: eur(money.total_minor), testId: "dq-total" },
              { label: "Déjà payé (cédant)", value: eur(money.paid_minor) },
              { label: "Restant dû", value: eur(money.outstanding_minor) },
              {
                label: "Annoncé par le cédant",
                value: rec.status === "no_control_totals" ? "Non fourni" : eur(money.control_minor),
              },
            ]}
          />
          <p className="mt-2 text-sm" data-testid="dq-reconciliation">
            {rec.status === "matched" ? (
              <Badge tone="ok">Totaux concordants au centime</Badge>
            ) : rec.status === "mismatch" ? (
              <Badge tone="error">Écart de {eur(money.difference_minor)} avec le cédant</Badge>
            ) : (
              <Badge tone="neutral">Pas de totaux cédant : rapprochement non effectué</Badge>
            )}
          </p>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <h3 className="mb-2 text-sm font-medium">Joignabilité</h3>
            <ul className="text-sm">
              <li>E-mail : {pct(report.contactability.email_pct)}</li>
              <li>Téléphone : {pct(report.contactability.phone_pct)}</li>
              <li>Adresse postale : {pct(report.contactability.postal_pct)}</li>
              <li>Au moins un moyen : {pct(report.contactability.any_pct)}</li>
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
                    <th className="p-2">Ligne</th>
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

// --- Commit, confirmation, rollback ------------------------------------------------------------------

export function IntegrationSection({
  batchId,
  status,
  report,
}: {
  batchId: string;
  status: string;
  report: DqReport | null;
}) {
  const hidden = <input type="hidden" name="batch_id" value={batchId} />;
  const staged = report?.staging?.entities ?? {};
  if (status === "needs_fix") {
    return (
      <Section title="Intégration">
        <InfoNote>
          Des anomalies bloquantes empêchent l&apos;intégration. Faites corriger le fichier par le cédant puis déposez-le dans
          un nouveau lot.
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
        <form action={commitBatch} className="flex flex-col gap-3">
          {hidden}
          <label className="flex flex-col gap-1 text-sm">
            {mismatch ? "Motif (obligatoire : les totaux ne concordent pas)" : "Commentaire (facultatif)"}
            <input name="reason" required={mismatch} className={inputClass} />
          </label>
          <button type="submit" className={inlineButtonClass}>
            Intégrer le lot
          </button>
        </form>
      </Section>
    );
  }
  if (status === "committed") {
    return (
      <Section title="Intégration" testId="integration">
        <InfoNote>
          Le lot est intégré mais aucun débiteur ne sera contacté avant confirmation par un responsable (mandat actif
          requis). Avant confirmation, l&apos;intégration peut être annulée.
        </InfoNote>
        <div className="mt-4 flex flex-col gap-4 sm:flex-row sm:items-end">
          <form action={confirmBatch}>
            {hidden}
            <button type="submit" className={inlineButtonClass}>
              Confirmer le lot
            </button>
          </form>
          <form action={rollbackBatch} className="flex flex-1 flex-col gap-2 sm:flex-row sm:items-end">
            {hidden}
            <label className="flex flex-1 flex-col gap-1 text-sm">
              Motif d&apos;annulation
              <input name="reason" required className={inputClass} />
            </label>
            <button type="submit" className={dangerButtonClass}>
              Annuler l&apos;intégration
            </button>
          </form>
        </div>
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
      </Section>
    );
  }
  return null;
}

// --- History ---------------------------------------------------------------------------------------------

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
          </li>
        ))}
      </ol>
    </Section>
  );
}
