import { notFound } from "next/navigation";
import { Badge, ErrorNote, InfoNote, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { isProcessing, statusLabel, statusTone } from "@/lib/boarding/status";
import { readinessText } from "@/lib/remittance/terms";
import { AutoRefresh } from "@/components/auto-refresh";
import {
  AbandonSection,
  type DqReport,
  type FileRow,
  FilesSection,
  HistorySection,
  IntegrationSection,
  type IssueRow,
  MappingSection,
  type Money,
  type OpeningTotals,
  type ProposalRow,
  QualitySection,
} from "./sections";

const JOB_FR: Record<string, string> = {
  profile: "analyse des fichiers",
  propose: "proposition de mapping",
  transform: "transformation et contrôles",
  stage: "préparation de l'intégration",
  commit: "intégration des données",
  documents: "rattachement des pièces",
  confirm: "confirmation et soldes d'ouverture",
  purge_documents: "suppression des pièces",
};

/** M1-19: one boarding batch, from upload to confirmation. */
export default async function BatchPage({ params }: PageProps<"/backoffice/reprises/[id]">) {
  const { id } = await params;
  const { supabase } = await staffSession();

  const { data: batch } = await supabase
    .from("boarding_batch")
    .select(
      "id, version, status, cut_off_date, dq_report, failed_job, opening_plan, opening_summary, client_organization_id," +
        " portfolio:portfolio_id(name), client:client_organization_id(legal_name)," +
        // Amounts as text: integer minor units never pass through a JS number.
        " total_minor:dq_report->reconciliation->computed->>total_minor," +
        " paid_minor:dq_report->reconciliation->computed->>paid_minor," +
        " outstanding_minor:dq_report->reconciliation->computed->>outstanding_minor," +
        " control_minor:dq_report->reconciliation->control->>total_minor," +
        " difference_minor:dq_report->reconciliation->>difference_minor",
    )
    .eq("id", id)
    .maybeSingle();
  if (!batch) notFound();
  const b = batch as unknown as {
    id: string;
    version: number;
    status: string;
    cut_off_date: string | null;
    dq_report: DqReport | null;
    failed_job: { type: string; error: string; at: string; blockers?: string[] } | null;
    client_organization_id: string;
    opening_plan: OpeningTotals | null;
    opening_summary: { entries: number; totals: OpeningTotals } | null;
    portfolio: { name: string } | null;
    client: { legal_name: string } | null;
  } & Money;

  const [{ data: files }, { data: events }, { data: proposals }, { data: issues }] = await Promise.all([
    supabase
      .from("boarding_file")
      .select("id, file_name, format, status, row_count, profile, error, duplicate_of_file_id")
      .eq("batch_id", id)
      .order("file_name"),
    supabase.from("boarding_event").select("id, from_status, to_status, reason, actor_label, at").eq("batch_id", id).order("id"),
    supabase
      .from("mapping_proposal")
      .select("id, file_id, source_column, target, confidence, rationale, needs_review, origin, status")
      .eq("batch_id", id)
      .order("source_column"),
    supabase
      .from("validation_issue")
      .select("id, file_id, row_number, source_column, code, severity, message, raw_value")
      .eq("batch_id", id)
      .order("severity")
      .order("row_number", { nullsFirst: true })
      .limit(50),
  ]);

  // M2c-2: what still keeps the portfolio from being confirmed (identities, the mandate's money terms; design §9.1).
  const readiness =
    b.status === "committed"
      ? (((await supabase.rpc("boarding_batch_readiness", { p_batch_id: id })).data ?? []) as string[])
      : [];
  const fileRows = (files ?? []) as unknown as FileRow[];
  const fileNames = Object.fromEntries(fileRows.map((f) => [f.id, f.file_name]));
  // A job that failed for good: blocks the page while processing; after commit (documents job)
  // it is shown as a warning, the batch itself being integrated. The documents job runs next to
  // the confirmation, so its failure does not stop the confirmation.
  const failedType = b.failed_job?.type ?? null;
  const documentsFailure = failedType === "documents" || failedType === "purge_documents";
  const failed = b.failed_job !== null && isProcessing(b.status) && !(b.status === "confirming" && documentsFailure);
  // "yyyy-mm-dd" is a calendar date: format it without a timezone shift.
  const cutOff = b.cut_off_date ? b.cut_off_date.split("-").reverse().join("/") : null;

  return (
    <WidePage
      title={`Lot n° ${b.version}`}
      back={{ href: "/backoffice/reprises", label: "Reprises" }}
      actions={
        <span role="status" aria-live="polite">
          <Badge tone={failed ? "error" : statusTone(b.status)} testId="batch-status">
            {failed ? "Traitement en échec" : statusLabel(b.status)}
          </Badge>
        </span>
      }
    >
      <AutoRefresh
        active={isProcessing(b.status) && !failed}
        abandonable={b.status !== "committing" && b.status !== "confirming"}
      />
      <p className="-mt-3 text-sm text-zinc-600 dark:text-zinc-400">
        {b.client?.legal_name} · {b.portfolio?.name}
        {cutOff ? ` · arrêté au ${cutOff}` : ""}
      </p>
      {failed && b.failed_job ? (
        <ErrorNote>
          L&apos;étape « {JOB_FR[b.failed_job.type] ?? b.failed_job.type} » a échoué après plusieurs tentatives. Vérifiez le
          fichier (format, encodage), puis abandonnez ce lot et déposez-en un nouveau. Détail technique :{" "}
          <span className="font-mono text-xs break-all">{b.failed_job.error}</span>
        </ErrorNote>
      ) : b.failed_job?.type === "commit" && b.status === "staged" ? (
        <ErrorNote>
          L&apos;intégration a échoué : rien n&apos;a été intégré et le lot est revenu à l&apos;état « Prêt à intégrer ».
          Réessayez ; si l&apos;échec se répète, abandonnez ce lot et contactez le support. Détail technique :{" "}
          <span className="font-mono text-xs break-all">{b.failed_job.error}</span>
        </ErrorNote>
      ) : b.failed_job?.type === "confirm" && b.status === "committed" ? (
        <ErrorNote>
          {b.failed_job.error === "not_ready" ? (
            <>
              La confirmation n&apos;a pas été faite : le portefeuille n&apos;était plus prêt quand elle a été traitée (
              {(b.failed_job.blockers ?? []).map(readinessText).join(" ; ")}). Aucun solde n&apos;a été
              comptabilisé. Complétez ces éléments, puis confirmez à nouveau.
            </>
          ) : b.failed_job.error === "mandate_inactive" ? (
            <>
              La confirmation n&apos;a pas été faite : aucun mandat actif ne couvre ce portefeuille à cette date (art. R124-3
              CPCE). Aucun solde n&apos;a été comptabilisé. Rattachez un mandat actif au portefeuille, puis confirmez à nouveau.
            </>
          ) : (
            <>
              La confirmation a échoué : aucun solde n&apos;a été comptabilisé et le lot est revenu à l&apos;état « Intégré, à
              confirmer ». Réessayez ; si l&apos;échec se répète, annulez l&apos;intégration et contactez le support. Détail
              technique : <span className="font-mono text-xs break-all">{b.failed_job.error}</span>
            </>
          )}
        </ErrorNote>
      ) : b.failed_job &&
        ((b.failed_job.type === "documents" && ["committed", "confirming", "confirmed"].includes(b.status)) ||
          (b.failed_job.type === "purge_documents" && b.status === "rolled_back")) ? (
        // Failures that still matter after the batch moved on: documents not linked after commit,
        // or files not deleted from storage after a rollback (personal data to erase).
        <ErrorNote>
          L&apos;étape « {JOB_FR[b.failed_job.type] ?? b.failed_job.type} » a échoué après plusieurs tentatives
          {b.failed_job.type === "documents"
            ? " : les pièces jointes n'ont pas été rattachées. Déposez le zip dans un nouveau lot (par exemple en plusieurs zips plus petits)."
            : " : les fichiers des pièces sont encore dans le stockage alors que le lot est annulé. Contactez le support pour les effacer."}{" "}
          Détail technique : <span className="font-mono text-xs break-all">{b.failed_job.error}</span>
        </ErrorNote>
      ) : isProcessing(b.status) ? (
        <InfoNote>Traitement en cours ({statusLabel(b.status).toLowerCase()})… la page se met à jour seule.</InfoNote>
      ) : null}

      <FilesSection files={fileRows} />
      {(proposals ?? []).length > 0 || b.status === "mapping_proposed" ? (
        <MappingSection
          batchId={b.id}
          editable={b.status === "mapping_proposed"}
          proposals={(proposals ?? []) as unknown as ProposalRow[]}
          files={fileRows}
        />
      ) : null}
      {b.dq_report ? (
        <QualitySection
          report={b.dq_report}
          money={b}
          issues={(issues ?? []) as unknown as IssueRow[]}
          fileNames={fileNames}
        />
      ) : null}
      <IntegrationSection
        batchId={b.id}
        status={b.status}
        report={b.dq_report}
        openingPlan={b.opening_plan}
        openingSummary={b.opening_summary}
        readiness={readiness}
        clientId={b.client_organization_id}
      />
      <HistorySection events={events ?? []} />
      <AbandonSection batchId={b.id} status={b.status} />
    </WidePage>
  );
}
