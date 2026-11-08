import { notFound } from "next/navigation";
import { Badge, ErrorNote, InfoNote, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { isProcessing, statusLabel, statusTone } from "@/lib/boarding/status";
import { AutoRefresh } from "./auto-refresh";
import {
  type DqReport,
  type FileRow,
  FilesSection,
  HistorySection,
  IntegrationSection,
  type IssueRow,
  MappingSection,
  type ProposalRow,
  QualitySection,
} from "./sections";

/** M1-19: one boarding batch, from upload to confirmation. */
export default async function BatchPage({ params, searchParams }: PageProps<"/backoffice/reprises/[id]">) {
  const { id } = await params;
  const { erreur } = await searchParams;
  const { supabase } = await staffSession();

  const { data: batch } = await supabase
    .from("boarding_batch")
    .select(
      "id, version, status, cut_off_date, dq_report, portfolio:portfolio_id(name), client:client_organization_id(legal_name)," +
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
    portfolio: { name: string } | null;
    client: { legal_name: string } | null;
    total_minor: string | null;
    paid_minor: string | null;
    outstanding_minor: string | null;
    control_minor: string | null;
    difference_minor: string | null;
  };

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

  const fileRows = (files ?? []) as unknown as FileRow[];
  const fileNames = Object.fromEntries(fileRows.map((f) => [f.id, f.file_name]));

  return (
    <WidePage
      title={`Lot n° ${b.version}`}
      back={{ href: "/backoffice/reprises", label: "Reprises" }}
      actions={
        <Badge tone={statusTone(b.status)} testId="batch-status">
          {statusLabel(b.status)}
        </Badge>
      }
    >
      <AutoRefresh active={isProcessing(b.status)} />
      <p className="-mt-3 text-sm text-zinc-600 dark:text-zinc-400">
        {b.client?.legal_name} · {b.portfolio?.name}
        {b.cut_off_date ? ` · arrêté au ${new Date(b.cut_off_date).toLocaleDateString("fr-FR")}` : ""}
      </p>
      {typeof erreur === "string" ? <ErrorNote>{erreur}</ErrorNote> : null}
      {isProcessing(b.status) ? (
        <InfoNote>Traitement en cours ({statusLabel(b.status).toLowerCase()})… la page se met à jour seule.</InfoNote>
      ) : null}

      <FilesSection files={fileRows} />
      {(proposals ?? []).length > 0 ? (
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
      <IntegrationSection batchId={b.id} status={b.status} report={b.dq_report} />
      <HistorySection events={events ?? []} />
    </WidePage>
  );
}
