import Link from "next/link";
import { randomUUID } from "node:crypto";
import { ActionForm } from "@/components/action-form";
import { AutoRefresh } from "@/components/auto-refresh";
import { Badge, InfoNote, Section, Stats, WidePage, inlineButtonClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { money } from "@/lib/payments/statements";
import { frenchDate } from "@/lib/remittance/runs";
import {
  ATTESTATION_LABEL,
  TRANSFER_KIND,
  TRANSFER_STATUS,
  type FileDetail,
  cashLines,
  downloadWarning,
  fileLive,
  fileStatus,
  holdLabel,
  parisDateTime,
} from "@/lib/remittance/transfers";
import { markSent } from "../actions";
import { CancelFile, PayeeMismatch } from "../file-actions";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * M2c-6a one transfer file (design §11, §17.3): what it holds (its PmtInf, our ids, the payees as on the RIB), the cash
 * check and the transfers held out when it was generated, every download, and its actions — « Télécharger » (the
 * second time past the warning), « Marquer comme transmis », cancel it (an attestation once downloaded), report a payee
 * name the bank did not match. Its transfers a page at a time.
 */
export default async function TransferFilePage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { id } = await params;
  const after = Number((await searchParams).apres ?? 0);
  const { supabase } = await staffSession();
  const back = { href: "/backoffice/reversements/virements", label: "Virements" };
  const { data } = UUID.test(id)
    ? await supabase.rpc("transfer_file_detail", { p_file_id: id, p_after_seq: Number.isFinite(after) ? after : 0, p_limit: 100 })
    : { data: null };
  if (!data) {
    return (
      <WidePage title="Fichier de virements" back={back}>
        <InfoNote>Fichier introuvable, ou réservé aux administrateurs et aux responsables des opérations.</InfoNote>
      </WidePage>
    );
  }
  const f = data as unknown as FileDetail;
  const status = fileStatus(f.status);
  const warning = downloadWarning(f);
  const downloadable = ["generated", "downloaded", "sent"].includes(f.status);
  const href = `/backoffice/reversements/virements/${f.id}/telecharger`;
  return (
    <WidePage title={`Fichier ${f.number}`} back={back}>
      <AutoRefresh active={f.status === "pending"} abandonable={false} everyMs={2000} maxMs={120_000} />
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={status.tone} testId="file-status">
          {status.label}
        </Badge>
        <span className="text-sm text-zinc-600 dark:text-zinc-400">
          {f.bank_account.label} (…{f.bank_account.iban_last4}) · {f.pain_version}
        </span>
      </div>
      <Stats
        items={[
          { label: "Virements", value: f.nb_of_txs, testId: "file-count" },
          { label: "Total (CtrlSum)", value: money(f.ctrl_sum_minor, f.currency), testId: "file-total" },
          {
            label: "Exécution demandée",
            value:
              f.first_execution_date === f.last_execution_date
                ? frenchDate(f.first_execution_date)
                : `${frenchDate(f.first_execution_date)} – ${frenchDate(f.last_execution_date)}`,
          },
          { label: "Téléchargements", value: f.download_count, testId: "file-downloads-count" },
        ]}
      />
      <p className="text-xs text-zinc-600 dark:text-zinc-400" data-testid="file-integrity">
        MsgId {f.number} · créé le {parisDateTime(f.created_at)}
        {f.generated_at ? ` · écrit le ${parisDateTime(f.generated_at)}` : ""}
        {f.file_sha256 ? ` · SHA-256 ${f.file_sha256.slice(0, 16)}…` : ""}
        {f.generated_at ? (f.xsd_validated ? " · schéma XSD ISO 20022 vérifié" : " · schéma XSD ISO 20022 non vérifié (schéma à intégrer)") : ""}
      </p>
      {f.late_reason ? <InfoNote>Exécution après la date limite de certains reversements — motif : {f.late_reason}</InfoNote> : null}
      {f.status === "failed" ? <InfoNote>Le fichier n&apos;a pas pu être écrit : {f.error}. Ses virements attendent le prochain fichier.</InfoNote> : null}
      {f.closed_at ? (
        <p className="text-sm" data-testid="file-closed">
          {status.label} le {parisDateTime(f.closed_at)} : {f.close_reason}
          {f.close_attestation ? ` (attestation : ${ATTESTATION_LABEL[f.close_attestation] ?? f.close_attestation})` : ""}
        </p>
      ) : null}

      {warning && downloadable ? (
        <p className="text-sm font-medium text-red-800 dark:text-red-200" data-testid="download-warning">
          {warning}
        </p>
      ) : null}
      <div className="flex flex-wrap items-center gap-2">
        {downloadable && f.download_count === 0 ? (
          <a href={href} className={inlineButtonClass} data-testid="file-download">
            Télécharger
          </a>
        ) : null}
        {downloadable && f.download_count > 0 ? (
          <details data-testid="file-download-again">
            <summary className="cursor-pointer text-sm underline underline-offset-4">Télécharger de nouveau</summary>
            <p className="mt-2 text-sm">{warning}.</p>
            <a href={`${href}?confirme=1`} className={`${inlineButtonClass} mt-2 inline-block`} data-testid="file-download-confirm">
              J&apos;ai compris : télécharger de nouveau
            </a>
          </details>
        ) : null}
        {f.status === "downloaded" ? (
          <ActionForm action={markSent} submitLabel="Marquer comme transmis" buttonClassName={inlineButtonClass} testId="file-mark-sent">
            <input type="hidden" name="idempotency_key" value={randomUUID()} />
            <input type="hidden" name="file_id" value={f.id} />
            <input type="hidden" name="expected_version" value={f.version} />
          </ActionForm>
        ) : null}
        {fileLive(f.status) ? (
          <CancelFile fileId={f.id} version={f.version} downloaded={f.download_count > 0} idempotencyKey={randomUUID()} />
        ) : null}
      </div>

      <Section title="Téléchargements" testId="file-downloads">
        {f.downloads.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Pas encore téléchargé.</p>
        ) : (
          <ul className="flex flex-col gap-1 text-sm">
            {f.downloads.map((d) => (
              <li key={d.n} data-testid="file-download-row">
                {d.n}. le {parisDateTime(d.at)} par {d.by ?? "un utilisateur"}
                {d.warning_acknowledged ? " (avertissement de double dépôt confirmé)" : ""}
              </li>
            ))}
          </ul>
        )}
      </Section>

      <Section title={`Virements du fichier (${f.nb_of_txs})`} testId="file-items">
        <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
          {f.items.map((t) => {
            const st = TRANSFER_STATUS[t.status] ?? { label: t.status, tone: "neutral" as const };
            return (
              <li key={t.seq} className="flex flex-col gap-1 py-3" data-testid="file-item">
                <span className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-medium">
                    {TRANSFER_KIND[t.kind] ?? t.kind}
                    {t.client_name ? ` — ${t.client_name}` : ""}
                  </span>
                  <span className="font-medium tabular-nums">{money(t.amount_minor, t.currency)}</span>
                </span>
                <span className="text-xs text-zinc-600 dark:text-zinc-400">
                  À {t.payee_name} (IBAN …{t.iban_last4}) · <span className="font-mono">{t.end_to_end_id}</span> · lot{" "}
                  {t.pmt_inf_id} · exécution le {frenchDate(t.execution_date ?? t.requested_execution_date)}
                  {t.run_id ? (
                    <>
                      {" · "}
                      <Link href={`/backoffice/reversements/${t.run_id}`} className="underline underline-offset-4">
                        {t.run_number}
                      </Link>
                    </>
                  ) : null}
                </span>
                <span className="flex flex-wrap items-center gap-2">
                  <Badge tone={st.tone}>{st.label}</Badge>
                  {t.late ? <Badge tone="action">Après la date limite</Badge> : null}
                  {t.debit_seen ? <Badge tone="ok">Débit vu sur un relevé</Badge> : null}
                  {t.payee_check_open ? <Badge tone="error">Nom non concordant signalé</Badge> : null}
                </span>
                {t.kind === "payout" && t.status === "in_file" && !t.payee_check_open && f.download_count > 0 ? (
                  <PayeeMismatch transferId={t.transfer_id} fileId={f.id} idempotencyKey={randomUUID()} />
                ) : null}
              </li>
            );
          })}
        </ul>
        {f.next_after_seq ? (
          <Link href={`/backoffice/reversements/virements/${f.id}?apres=${f.next_after_seq}`} className="mt-2 inline-block text-sm underline underline-offset-4">
            Virements suivants
          </Link>
        ) : null}
      </Section>

      <Section title="Contrôle de trésorerie à la génération" testId="file-cash">
        <ul className="flex flex-col gap-1 text-sm">
          {cashLines(f.cash_check, f.currency).map((l) => (
            <li key={l}>{l}</li>
          ))}
          <li>ce fichier : {money(f.ctrl_sum_minor, f.currency)}</li>
          {f.cash_check.sweep_left_minor && f.cash_check.sweep_left_minor !== "0" ? (
            <li>quote-part du cabinet laissée pour un prochain fichier : {money(f.cash_check.sweep_left_minor, f.currency)}</li>
          ) : null}
        </ul>
      </Section>

      {f.held.length > 0 ? (
        <Section title={`Retenus hors du fichier (${f.held.length})`} testId="file-held">
          <ul className="flex flex-col gap-2 text-sm">
            {f.held.map((h) => (
              <li key={h.transfer_id}>
                {TRANSFER_KIND[h.kind] ?? h.kind}
                {h.client_name ? ` — ${h.client_name}` : ""} : {money(h.amount_minor, f.currency)} — {holdLabel(h.reason)}
              </li>
            ))}
          </ul>
        </Section>
      ) : null}
    </WidePage>
  );
}
