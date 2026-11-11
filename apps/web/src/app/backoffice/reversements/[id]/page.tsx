import Link from "next/link";
import { notFound } from "next/navigation";
import { ActionForm } from "@/components/action-form";
import { AutoRefresh } from "@/components/auto-refresh";
import { Badge, InfoNote, Section, Stats, WidePage, dangerButtonClass, inlineButtonClass, inputClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { money } from "@/lib/payments/statements";
import {
  type RunCard,
  TRIGGER_LABEL,
  blockerLabel,
  deadlineChip,
  failureNote,
  frenchDate,
  percentText,
  refundNote,
  runBusy,
  runStatus,
} from "@/lib/remittance/runs";
import { runStatementState } from "@/lib/remittance/documents";
import { fileStatus, runCancelPath } from "@/lib/remittance/transfers";
import { cancelRun, discardRun, refreshRun } from "../actions";
import { ApprovePanel } from "../approve-panel";

type Part = {
  rule_id: string;
  label_fr: string;
  tiers: [string, string][];
  commission: string;
  held: string;
  minimum: boolean;
  capped: boolean;
  kept: boolean;
  basis_before: string;
};
type DetailLine = {
  line_no: number;
  kind: string;
  account_id: string | null;
  file_ref: string | null;
  amount_minor: string;
  encaissement_date: string | null;
  latest_execution_date: string | null;
  unmeetable: boolean;
  commission_minor: string;
  commission_state: string;
  commission_reason: string | null;
  parts: Part[];
};
type DetailDoc = {
  id?: string;
  kind: string;
  number: string | null;
  issue_date?: string;
  reason?: string;
  mandate_reference: string | null;
  ht_minor: string;
  vat_minor: string;
  ttc_minor: string;
  settlement: string | null;
  payload_sha256?: string;
  lines: { designation_fr: string; kind: string; ht_minor?: string; ht?: string }[];
  corrects: string[];
};
type Detail = {
  run: RunCard;
  lines: DetailLine[];
  offset: number;
  limit: number;
  documents: DetailDoc[];
  transfer: {
    status: string;
    end_to_end_id: string;
    amount_minor: string;
    requested_execution_date: string;
    payee_name: string;
    iban_last4: string;
    remittance_info: string;
  } | null;
  service_from: string | null;
  service_to: string | null;
  today: string;
  next_business_day: string;
  can_approve: boolean;
  can_cancel: boolean;
};

const LINE_KIND: Record<string, string> = {
  allocation: "Encaissement imputé",
  allocation_reversal: "Imputation annulée",
  forward: "Reversement sans imputation",
  forward_reversal: "Reversement sans imputation annulé",
  client_advance: "Avance du cabinet",
  client_advance_reversal: "Avance annulée",
  payout_returned: "Virement revenu",
  unplanned_payout: "Virement non prévu",
};
const TRANSFER_STATUS: Record<string, string> = {
  ordered: "Ordonné — à mettre dans un fichier de virements",
  in_file: "Dans un fichier de virements",
  booked: "Débité",
  returned: "Revenu",
  cancelled: "Annulé",
};

/** « Pourquoi cette commission ? » (§17.2): the rule, the bands, the minimum, the cap, the hold, as the engine priced. */
function whyCommission(l: DetailLine, currency: string): string {
  if (l.commission_state === "pending") return "Commission en attente : facturée par un prochain reversement.";
  if (l.commission_state === "none") return "Pas de commission sur cette ligne.";
  if (l.parts.length === 0) return "Encaissement annulé dans le même reversement : jamais facturé.";
  return l.parts
    .map((p) => {
      const bands = p.tiers.map(([r, b]) => `${percentText(r)} sur ${money(b, currency)}`).join(" puis ");
      const notes = [
        p.minimum ? "minimum par dossier" : null,
        p.capped ? "plafonnée à ce que le dossier a rapporté" : null,
        p.kept ? "conservée par la clause du mandat" : null,
        p.held !== "0" ? `${money(p.held, currency)} retenus (arrondi de TVA)` : null,
      ].filter(Boolean);
      return `${p.label_fr} : ${bands || "régularisation de paliers"} (déjà encaissé sur le dossier : ${money(p.basis_before, currency)})${notes.length ? ` — ${notes.join(", ")}` : ""}`;
    })
    .join(" ; ");
}

/**
 * M2c-4 one run (design §17.2): the summary as the statement will say it, the lines per file (paged) with « Pourquoi
 * cette commission ? », its invoices and credit notes (numbers once approved), the transfer, and its actions —
 * « Valider », « Actualiser », « Abandonner » a draft; « Annuler » an approved run before its file (a credit note is
 * issued). Money staff; cancellation: admins (the database decides).
 */
export default async function RemittanceRunPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { id } = await params;
  const page = Math.max(0, Number((await searchParams).page ?? 0) || 0);
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { supabase } = await staffSession();
  const { data, error } = await supabase.rpc("remittance_run_detail", { p_run_id: id, p_offset: page * 50, p_limit: 50 });
  if (error || !data) notFound();
  const d = data as unknown as Detail;
  const r = d.run;
  // M2c-5: the statement and the invoices' PDFs, once the documents job has drawn them
  const docIds = d.documents.map((x) => x.id).filter((x): x is string => Boolean(x));
  // M2c-6a: the file holding the payout (« Virements »), and whether it was downloaded (its transfer is then cancelled
  // first, in two steps: review T1)
  const [{ data: statement }, { data: pdfs }, { data: inFile }] = await Promise.all([
    supabase
      .from("remittance_statement")
      .select("number, issue_date, pdf_document_id, pdf_sha256, csv_document_id, csv_sha256, line_count, file_count")
      .eq("run_id", id)
      .maybeSingle(),
    docIds.length > 0
      ? supabase.from("commission_invoice_document").select("invoice_id, document_id, pdf_sha256, electronic").in("invoice_id", docIds)
      : Promise.resolve({ data: [] as { invoice_id: string; document_id: string; pdf_sha256: string; electronic: boolean }[] }),
    supabase
      .from("bank_transfer")
      .select("transfer_file_id, transfer_file:transfer_file_id(number, status, download_count)")
      .eq("run_id", id)
      .neq("status", "cancelled")
      .maybeSingle(),
  ]);
  const transferFile = inFile?.transfer_file_id
    ? { id: inFile.transfer_file_id, ...(inFile.transfer_file as unknown as { number: string; status: string; download_count: number }) }
    : null;
  // review T1 (money#2): a payout in a downloaded file is cancelled first (two people, the statement's evidence), then the run
  const cancelPath = runCancelPath(d.transfer ?? null, transferFile);
  const pdfOf = new Map((pdfs ?? []).map((x) => [x.invoice_id, x]));
  const status = runStatus(r);
  const chip = deadlineChip(r.earliest_latest_execution_date, r.deadline_state);
  // a job in flight refreshes the page; a failed preparation does not (it waits for « Actualiser »)
  const busy = runBusy(r);
  const draft = r.status === "draft";
  const refund = refundNote(r);
  // review M2c-5 (perf#6 = tests-ui#3): only an approved run gets a statement — a draft discarded or cancelled before
  // its approval never does, so the page neither polls for it nor says « en préparation »
  const statementState = runStatementState(r, statement ?? null);
  return (
    <WidePage title={`${r.client_name} · ${r.number}`} back={{ href: "/backoffice/reversements", label: "Reversements" }}>
      <AutoRefresh active={busy || statementState === "pending"} abandonable={false} everyMs={2000} maxMs={120_000} />
      <div className="flex flex-wrap gap-2">
        <Badge tone={status.tone} testId="run-status">
          {status.label}
        </Badge>
        {chip ? <Badge tone={chip.tone}>{chip.label}</Badge> : null}
        <Badge tone="neutral">{TRIGGER_LABEL[r.trigger] ?? r.trigger}</Badge>
      </div>
      {r.last_failure ? <InfoNote>{failureNote(r.last_failure)}.</InfoNote> : null}
      {r.blockers.map((b) => (
        <InfoNote key={b}>Virement bloqué : {blockerLabel(b)}.</InfoNote>
      ))}
      <Stats
        items={[
          { label: "Brut", value: r.gross_minor !== null ? money(r.gross_minor, r.currency) : "—", testId: "run-gross" },
          {
            label: "Commission TTC (factures − avoirs)",
            value:
              r.invoice_ttc_minor !== null && r.credit_ttc_minor !== null
                ? money((BigInt(r.invoice_ttc_minor) - BigInt(r.credit_ttc_minor)).toString(), r.currency)
                : "—",
          },
          { label: "Compensation", value: r.settlement_minor !== null ? money(r.settlement_minor, r.currency) : "—" },
          { label: "Net à virer", value: r.net_minor !== null ? money(r.net_minor, r.currency) : "—", testId: "run-net" },
        ]}
      />
      <p className="text-sm text-zinc-600 dark:text-zinc-400">
        Période : {d.service_from ? frenchDate(d.service_from) : "—"} → {d.service_to ? frenchDate(d.service_to) : "—"}
        {refund ? ` · ${refund}` : ""}
        {r.requested_execution_date ? ` · exécution demandée le ${frenchDate(r.requested_execution_date)}` : ""}
      </p>

      {draft && r.prepared_at && d.can_approve ? (
        <ApprovePanel runs={[r]} today={d.today} nextBusinessDay={d.next_business_day} canApprove />
      ) : null}
      {draft && r.job === null && d.can_approve ? (
        <div className="flex flex-wrap gap-2">
          <ActionForm action={refreshRun} submitLabel="Actualiser" buttonClassName={inlineButtonClass} testId="run-refresh">
            <input type="hidden" name="idempotency_key" value={crypto.randomUUID()} />
            <input type="hidden" name="run_id" value={r.id} />
            <input type="hidden" name="expected_version" value={r.version} />
          </ActionForm>
          <ActionForm action={discardRun} submitLabel="Abandonner" buttonClassName={dangerButtonClass} testId="run-discard" className="flex flex-col gap-2">
            <input type="hidden" name="idempotency_key" value={crypto.randomUUID()} />
            <input type="hidden" name="run_id" value={r.id} />
            <input type="hidden" name="expected_version" value={r.version} />
            <input name="reason" className={inputClass} placeholder="Motif (interne)" aria-label="Motif de l'abandon" required />
          </ActionForm>
        </div>
      ) : null}
      {(r.status === "approved" || r.status === "sent") && d.can_cancel && cancelPath === "transfer_first" && transferFile ? (
        <div className="flex flex-col gap-2 text-sm" data-testid="run-cancel-transfer-first">
          <p>
            Le virement est dans le fichier {transferFile.number}, déjà téléchargé : faites d&apos;abord annuler ce virement — une
            demande, puis la confirmation d&apos;une autre personne, une fois importé le relevé du jour d&apos;exécution et du jour
            ouvré suivant, sans son débit. Le reversement pourra ensuite être annulé (un avoir pour chaque facture, les
            encaissements de nouveau en attente).
          </p>
          <Link href={`/backoffice/reversements/virements/${transferFile.id}`} className="underline underline-offset-4" data-testid="run-cancel-transfer-link">
            Annuler le virement dans le fichier {transferFile.number}
          </Link>
        </div>
      ) : null}
      {(r.status === "approved" || r.status === "sent") && d.can_cancel && cancelPath === "direct" ? (
        <ActionForm action={cancelRun} submitLabel="Annuler le reversement" buttonClassName={dangerButtonClass} testId="run-cancel" className="flex flex-col gap-2">
          <p className="text-sm">
            {d.transfer?.status === "cancelled"
              ? "Son virement a été annulé (la banque ne l'a pas exécuté, relevé à l'appui, confirmé par une autre personne) : le reversement est annulé, un avoir est émis pour chaque facture, et les encaissements reviennent en attente pour un prochain reversement."
              : "Le virement n'est pas encore parti : il est annulé (son fichier, s'il n'a pas été téléchargé, est remplacé), un avoir est émis pour chaque facture, et les encaissements reviennent en attente pour un prochain reversement."}
          </p>
          <input type="hidden" name="idempotency_key" value={crypto.randomUUID()} />
          <input type="hidden" name="run_id" value={r.id} />
          <input type="hidden" name="expected_version" value={r.version} />
          <input name="reason" className={inputClass} placeholder="Motif (interne)" aria-label="Motif de l'annulation" required />
        </ActionForm>
      ) : null}

      <Section title={draft ? "Factures et avoirs à émettre" : "Factures et avoirs"} testId="run-documents">
        {d.documents.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucune facture : pas de commission sur ce reversement.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
            {d.documents.map((doc, i) => (
              <li key={doc.id ?? `${doc.kind}-${i}`} className="flex flex-col gap-1 py-3" data-testid="run-document">
                <span className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-medium">
                    {doc.id && doc.number ? (
                      // M2c-5b: the invoice's page (what it still charges, its credit notes, « Émettre un avoir »)
                      <Link href={`/backoffice/reversements/factures/${doc.id}`} className="underline underline-offset-4" data-testid="run-document-link">
                        {doc.kind === "invoice" ? "Facture" : "Avoir"} {doc.number}
                      </Link>
                    ) : (
                      <>
                        {doc.kind === "invoice" ? "Facture" : "Avoir"} {doc.number ?? "(numérotée à la validation)"}
                      </>
                    )}
                    {doc.mandate_reference ? ` · mandat ${doc.mandate_reference}` : ""}
                  </span>
                  <span className="tabular-nums">{money(doc.ttc_minor, r.currency)} TTC</span>
                </span>
                <span className="text-sm text-zinc-600 dark:text-zinc-400">
                  HT {money(doc.ht_minor, r.currency)} · TVA {money(doc.vat_minor, r.currency)}
                  {doc.issue_date ? ` · émise le ${frenchDate(doc.issue_date)}` : ""}
                  {doc.settlement === "netted" ? " · à régler par compensation" : doc.settlement === "due" ? " · à régler au compte propre" : ""}
                  {doc.corrects.length > 0 ? ` · rectifie ${doc.corrects.join(", ")}` : ""}
                </span>
                <ul className="list-disc pl-5 text-sm">
                  {doc.lines.map((l, j) => (
                    <li key={j}>{l.designation_fr}</li>
                  ))}
                </ul>
                {doc.id && pdfOf.get(doc.id) ? (
                  <span className="flex flex-wrap items-center gap-2 text-sm">
                    <a
                      href={`/backoffice/reversements/documents/${pdfOf.get(doc.id)?.document_id}`}
                      className="font-medium underline underline-offset-4"
                      data-testid="run-document-pdf"
                    >
                      PDF
                    </a>
                    {pdfOf.get(doc.id)?.electronic ? null : (
                      <Badge tone="action" testId="run-document-post">
                        À envoyer par courrier (pas d&apos;accord pour la facture électronique)
                      </Badge>
                    )}
                    <span className="break-all text-xs text-zinc-500">SHA-256 {pdfOf.get(doc.id)?.pdf_sha256}</span>
                  </span>
                ) : doc.id ? (
                  <span className="break-all text-xs text-zinc-500">
                    PDF en préparation · SHA-256 des données : {doc.payload_sha256}
                  </span>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </Section>

      {statementState === "none" ? (
        <Section title="Relevé de reversement" testId="run-statement">
          <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="run-statement-none">
            Aucun relevé : reversement abandonné avant sa validation.
          </p>
        </Section>
      ) : statementState !== "draft" ? (
        <Section title="Relevé de reversement" testId="run-statement">
          {statement ? (
            <div className="flex flex-col gap-1 text-sm">
              <span>
                Relevé {statement.number} du {frenchDate(statement.issue_date)} · {statement.line_count} encaissement(s) ·{" "}
                {statement.file_count} dossier(s)
              </span>
              <span className="flex flex-wrap gap-4">
                <a
                  href={`/backoffice/reversements/documents/${statement.pdf_document_id}`}
                  className="font-medium underline underline-offset-4"
                  data-testid="run-statement-pdf"
                >
                  Relevé (PDF)
                </a>
                <a
                  href={`/backoffice/reversements/documents/${statement.csv_document_id}`}
                  className="font-medium underline underline-offset-4"
                  data-testid="run-statement-csv"
                >
                  Détail (CSV)
                </a>
              </span>
              <span className="break-all text-xs text-zinc-500">
                PDF SHA-256 {statement.pdf_sha256} · CSV SHA-256 {statement.csv_sha256}
              </span>
            </div>
          ) : (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">Relevé en préparation.</p>
          )}
        </Section>
      ) : null}

      {d.transfer ? (
        <Section title="Virement" testId="run-transfer">
          <p className="text-sm">
            {money(d.transfer.amount_minor, r.currency)} à {d.transfer.payee_name} (IBAN …{d.transfer.iban_last4}), exécution
            demandée le {frenchDate(d.transfer.requested_execution_date)} — {TRANSFER_STATUS[d.transfer.status] ?? d.transfer.status}.
          </p>
          <p className="text-xs text-zinc-500">
            Référence {d.transfer.end_to_end_id} · {d.transfer.remittance_info}
          </p>
          {transferFile ? (
            <p className="text-sm" data-testid="run-transfer-file">
              Fichier{" "}
              <Link href={`/backoffice/reversements/virements/${transferFile.id}`} className="underline underline-offset-4">
                {transferFile.number}
              </Link>{" "}
              — {fileStatus(transferFile.status).label}
            </p>
          ) : d.transfer.status === "ordered" ? (
            <p className="text-sm">
              <Link href="/backoffice/reversements/virements" className="underline underline-offset-4">
                Mettre dans un fichier de virements
              </Link>
            </p>
          ) : null}
        </Section>
      ) : null}

      <Section title={`Lignes (${r.line_count ?? r.item_count})`} testId="run-lines">
        <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
          {d.lines.map((l) => (
            <li key={l.line_no} className="flex flex-col gap-1 py-3" data-testid="run-line">
              <span className="flex flex-wrap items-center justify-between gap-2">
                <span>
                  {LINE_KIND[l.kind] ?? l.kind}
                  {l.file_ref ? (
                    <>
                      {" · "}
                      <Link href={`/backoffice/dossiers/${l.account_id}`} className="underline underline-offset-4">
                        {l.file_ref}
                      </Link>
                    </>
                  ) : null}
                </span>
                <span className="tabular-nums">{money(l.amount_minor, r.currency)}</span>
              </span>
              <span className="text-sm text-zinc-600 dark:text-zinc-400">
                {l.encaissement_date ? `encaissé le ${frenchDate(l.encaissement_date)}` : ""}
                {l.latest_execution_date ? ` · à exécuter au plus tard le ${frenchDate(l.latest_execution_date)}` : ""}
                {l.unmeetable ? " · délai intenable" : ""}
                {` · commission ${money(l.commission_minor, r.currency)} HT`}
              </span>
              <details className="text-sm">
                <summary className="cursor-pointer underline-offset-4 hover:underline">Pourquoi cette commission ?</summary>
                <p className="mt-1">{whyCommission(l, r.currency)}</p>
              </details>
            </li>
          ))}
        </ul>
        <div className="mt-3 flex gap-3 text-sm">
          {page > 0 ? (
            <Link href={`/backoffice/reversements/${r.id}?page=${page - 1}`} className="underline underline-offset-4">
              ← Précédentes
            </Link>
          ) : null}
          {d.lines.length === d.limit ? (
            <Link href={`/backoffice/reversements/${r.id}?page=${page + 1}`} className="underline underline-offset-4">
              Suivantes →
            </Link>
          ) : null}
        </div>
      </Section>
    </WidePage>
  );
}
