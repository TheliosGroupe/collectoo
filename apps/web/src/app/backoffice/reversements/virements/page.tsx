import Link from "next/link";
import { randomUUID } from "node:crypto";
import { ActionForm } from "@/components/action-form";
import { AutoRefresh } from "@/components/auto-refresh";
import { Badge, InfoNote, Section, WidePage, inlineButtonClass, inputClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { money } from "@/lib/payments/statements";
import { frenchDate } from "@/lib/remittance/runs";
import {
  PAIN_VERSIONS,
  SERVICER_FUNDS_UNSWEPT_NOTE,
  TRANSFER_KIND,
  type FileCard,
  type PayingAccount,
  type TransferCard,
  type TransferOverview,
  canGenerate,
  cancellationOf,
  cashLines,
  downloadWarning,
  fileLive,
  fileStale,
  fileStatus,
  generateLabel,
  generationEffects,
  holdLabel,
  parisDateTime,
  payeeCheckClearable,
  requestLine,
  sweepHoldLabel,
} from "@/lib/remittance/transfers";
import {
  TOP_UP_FILE_STATUS,
  TOP_UP_SECTION_ANCHOR,
  TOP_UP_SECTION_NOTE,
  TOP_UP_SECTION_TITLE,
  TOP_UP_STATUS_LABEL,
  TOP_UP_STATUS_TONE,
  type TopUpFile,
  type TopUpOverview,
  neededLine,
  orderedBy,
} from "@/lib/remittance/top-ups";
import { clearPayeeMismatch, markSent, setPainVersion } from "./actions";
import { DownloadLink, GenerateFile } from "./file-actions";
import { CancelTopUpFile, CancelTopUpOrder, GenerateTopUpFile } from "./top-up-actions";

/** One transfer waiting for a file: what, to whom, and why it would be held out today. */
function TransferRow({
  t,
  currency,
  cancellationAfterDownload = false,
}: {
  t: TransferCard;
  currency: string;
  /** M2c-6b-3a review round 1 (tests-6): the flag « Virements » read — the hold's « on » words */
  cancellationAfterDownload?: boolean;
}) {
  const hold = holdLabel(t.hold, cancellationAfterDownload);
  return (
    <li className="flex flex-col gap-1 py-3" data-testid="transfer-row">
      <span className="flex flex-wrap items-center justify-between gap-2">
        <span className="font-medium">
          {TRANSFER_KIND[t.kind] ?? t.kind}
          {t.client_name ? ` — ${t.client_name}` : ""}
        </span>
        <span className="font-medium tabular-nums">{money(t.amount_minor, currency)}</span>
      </span>
      <span className="text-xs text-zinc-600 dark:text-zinc-400">
        À {t.payee_name} (IBAN …{t.iban_last4}) · référence <span className="font-mono">{t.end_to_end_id}</span>
        {t.execution_date ? ` · exécution le ${frenchDate(t.execution_date)}` : ""}
        {t.run_id ? (
          <>
            {" · "}
            <Link href={`/backoffice/reversements/${t.run_id}`} className="underline underline-offset-4">
              {t.run_number}
            </Link>
          </>
        ) : null}
        {t.payment_id ? (
          <>
            {" · "}
            <Link href={`/backoffice/encaissements/paiements/${t.payment_id}`} className="underline underline-offset-4">
              paiement remboursé
            </Link>
          </>
        ) : null}
      </span>
      {hold ? (
        <span className="text-sm text-amber-900 dark:text-amber-200" data-testid="transfer-hold">
          {hold}
        </span>
      ) : null}
    </li>
  );
}

/**
 * A file of the account: status, totals, its download (with the second-download warning) and « transmis ». A generated
 * file whose execution date has passed is not offered for download (review T2: the download would refuse and replace
 * it): « Régénérer le fichier » below does it. A cancellation asked after download says who asked (review T1).
 */
function FileRow({ f, earliest }: { f: FileCard; earliest: string }) {
  const status = fileStatus(f.status);
  const warning = downloadWarning(f);
  const stale = fileStale(f, earliest);
  const downloadable = ["generated", "downloaded", "sent"].includes(f.status) && !stale;
  const href = `/backoffice/reversements/virements/${f.id}/telecharger`;
  const request = cancellationOf(f.cancellation).request;
  return (
    <li className="flex flex-col gap-2 py-3" data-testid="file-row">
      <span className="flex flex-wrap items-center justify-between gap-2">
        <Link href={`/backoffice/reversements/virements/${f.id}`} className="font-medium underline underline-offset-4">
          {f.number}
        </Link>
        <Badge tone={stale ? "error" : status.tone} testId="file-status">
          {stale ? "Date d'exécution dépassée — à régénérer" : status.label}
        </Badge>
      </span>
      <span className="text-sm">
        {f.nb_of_txs} virement{f.nb_of_txs > 1 ? "s" : ""} · {money(f.ctrl_sum_minor, f.currency)} · exécution le{" "}
        {frenchDate(f.first_execution_date)}
        {f.last_execution_date !== f.first_execution_date ? ` au ${frenchDate(f.last_execution_date)}` : ""}
      </span>
      <span className="text-xs text-zinc-600 dark:text-zinc-400">
        Créé le {parisDateTime(f.created_at)} · {f.pain_version}
        {f.status === "generated" || f.download_count > 0 ? (f.xsd_validated ? " · schéma XSD vérifié" : " · schéma XSD non vérifié") : ""}
        {f.sent_marked_at ? ` · transmis le ${parisDateTime(f.sent_marked_at)}${f.sent_marked_by ? ` par ${f.sent_marked_by}` : ""}` : ""}
        {f.status === "failed" && f.error ? ` · ${f.error}` : ""}
      </span>
      {stale ? (
        <p className="text-sm text-red-800 dark:text-red-200" data-testid="file-stale">
          Sa date d&apos;exécution est passée : il ne peut plus être téléchargé. Régénérez-le (nouveau numéro, nouvelle date).
        </p>
      ) : null}
      {warning && downloadable ? (
        <p className="text-sm font-medium text-red-800 dark:text-red-200" data-testid="download-warning">
          {warning}
        </p>
      ) : null}
      {request ? (
        <p className="text-sm text-amber-900 dark:text-amber-200" data-testid="file-cancel-request">
          {requestLine(request)} — {request.requested_by_me ? "une autre personne doit la confirmer" : "à confirmer sur la page du fichier"}.
        </p>
      ) : null}
      <span className="flex flex-wrap items-center gap-2">
        {downloadable && f.download_count === 0 ? <DownloadLink href={href} label="Télécharger" testId="file-download" /> : null}
        {downloadable && f.download_count > 0 ? (
          <details data-testid="file-download-again">
            <summary className="cursor-pointer text-sm underline underline-offset-4">Télécharger de nouveau</summary>
            <p className="mt-2 text-sm">{warning}.</p>
            <DownloadLink
              href={`${href}?confirme=1`}
              label="J'ai compris : télécharger de nouveau"
              testId="file-download-confirm"
              className={`${inlineButtonClass} mt-2 inline-block`}
            />
          </details>
        ) : null}
        {f.status === "downloaded" ? (
          <ActionForm action={markSent} submitLabel="Marquer comme transmis" buttonClassName={inlineButtonClass} testId="file-mark-sent">
            <input type="hidden" name="idempotency_key" value={randomUUID()} />
            <input type="hidden" name="file_id" value={f.id} />
            <input type="hidden" name="expected_version" value={f.version} />
          </ActionForm>
        ) : null}
      </span>
    </li>
  );
}

function Account({ a, overview }: { a: PayingAccount; overview: TransferOverview }) {
  const live = a.files.filter((f) => ["pending", "generated", "downloaded", "sent"].includes(f.status));
  const past = a.files.filter((f) => !live.includes(f));
  const sepa = a.currency === "EUR";
  return (
    <Section title={`${a.label} (…${a.iban_last4})`} testId="paying-account">
      <div className="flex flex-col gap-4" id={`compte-${a.bank_account_id}`}>
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          Fichiers {a.pain_version}
          {a.bic ? ` · BIC ${a.bic}` : " · BIC non renseigné (NOTPROVIDED)"} · exécution au plus tôt le{" "}
          {frenchDate(a.earliest_execution_date)}
        </p>
        <ul className="flex flex-col gap-1 rounded-md bg-zinc-50 p-3 text-sm dark:bg-zinc-900" data-testid="cash-check">
          {cashLines(a.cash, a.currency).map((l) => (
            <li key={l}>{l}</li>
          ))}
        </ul>
        <div>
          <h3 className="font-medium">
            À mettre dans un fichier ({a.to_file_count}) — {money(a.eligible_total_minor, a.currency)} prêts
          </h3>
          {a.to_file.length === 0 ? (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun reversement ni remboursement en attente de fichier.</p>
          ) : (
            <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
              {a.to_file.map((t) => (
                <TransferRow
                  key={t.transfer_id}
                  t={t}
                  currency={a.currency}
                  cancellationAfterDownload={overview.cancellation_after_download === true}
                />
              ))}
            </ul>
          )}
          {a.to_file_count > a.to_file.length ? (
            <p className="text-xs text-zinc-500">Les {a.to_file.length} plus anciens sont affichés ; le fichier les prend tous.</p>
          ) : null}
          {a.sweep_preview_minor !== "0" ? (
            <p className="mt-2 text-sm" data-testid="sweep-preview">
              Quote-part du cabinet à virer au compte propre : {money(a.sweep_preview_minor, a.currency)}
              {overview.own_account ? ` (…${overview.own_account.iban_last4})` : " — aucun compte propre renseigné"}.
            </p>
          ) : null}
          {sweepHoldLabel(a.sweep_hold, overview.cancellation_after_download === true) ? (
            <p className="mt-2 text-sm text-red-800 dark:text-red-200" data-testid="sweep-hold">
              {sweepHoldLabel(a.sweep_hold, overview.cancellation_after_download === true)}.
            </p>
          ) : null}
        </div>
        {canGenerate(a) ? (
          <GenerateFile
            accountId={a.bank_account_id}
            effects={generationEffects(a, overview.own_account)}
            lateCount={a.late_count}
            idempotencyKey={randomUUID()}
            label={generateLabel(a)}
          />
        ) : null}
        {!sepa ? <InfoNote>Les fichiers SEPA sont en euros : ce compte n&apos;en produit pas.</InfoNote> : null}
        <div>
          <h3 className="font-medium">Fichiers</h3>
          {a.files.length === 0 ? (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun fichier.</p>
          ) : (
            <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800" data-testid="files">
              {[...live, ...past].map((f) => (
                <FileRow key={f.id} f={f} earliest={a.earliest_execution_date} />
              ))}
            </ul>
          )}
        </div>
        {overview.can_admin ? (
          <ActionForm action={setPainVersion} submitLabel="Changer le format" buttonClassName={inlineButtonClass} className="flex flex-wrap items-end gap-2">
            <input type="hidden" name="idempotency_key" value={randomUUID()} />
            <input type="hidden" name="bank_account_id" value={a.bank_account_id} />
            <label className="flex flex-col gap-1 text-sm">
              Format demandé par la banque
              <select name="pain_version" defaultValue={a.pain_version} className={inputClass}>
                {PAIN_VERSIONS.map((v) => (
                  <option key={v} value={v}>
                    {v}
                  </option>
                ))}
              </select>
            </label>
          </ActionForm>
        ) : null}
      </div>
    </Section>
  );
}

/**
 * M2c-7e-1 « Approvisionnements du compte dédié » (plan §7.4): per own account, the TOP orders (date, amount, reference,
 * « commandé automatiquement » or by whom, status), « Générer le fichier (compte propre) », its files with « Télécharger »
 * and « Annuler le fichier » (before or after download, whatever the switch), « Annuler » an order. What the servicer
 * still owes the dedicated account beyond the orders, per currency. Admins and ops managers (the database checks it).
 */
function TopUpSection({ o }: { o: TopUpOverview }) {
  return (
    <Section title={TOP_UP_SECTION_TITLE} testId="top-up-section">
      <div className="flex flex-col gap-4" id={TOP_UP_SECTION_ANCHOR}>
        <p className="text-sm text-zinc-600 dark:text-zinc-400">{TOP_UP_SECTION_NOTE}</p>
        {o.needed.length > 0 ? (
          <ul className="flex flex-col gap-1 rounded-md bg-zinc-50 p-3 text-sm dark:bg-zinc-900" data-testid="top-up-needed">
            {o.needed.map((n) => (
              <li key={n.currency}>{neededLine(n)}</li>
            ))}
          </ul>
        ) : null}
        {o.accounts.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun compte propre actif.</p>
        ) : null}
        {o.accounts.map((a) => {
          const live = a.files.filter((f) => fileLive(f.status));
          const past = a.files.filter((f) => !live.includes(f));
          return (
            <div key={a.bank_account_id} className="flex flex-col gap-3" data-testid="own-account">
              <h3 className="font-medium">
                {a.label} (…{a.iban_last4}) · {a.currency}
              </h3>
              <p className="text-xs text-zinc-600 dark:text-zinc-400">
                Fichiers {a.pain_version}
                {a.bic ? ` · BIC ${a.bic}` : " · BIC non renseigné (NOTPROVIDED)"} · exécution au plus tôt le{" "}
                {frenchDate(a.earliest_execution_date)}
              </p>
              {a.top_ups.length === 0 ? (
                <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun approvisionnement.</p>
              ) : (
                <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800" data-testid="top-ups">
                  {a.top_ups.map((t) => (
                    <li key={t.transfer_id} className="flex flex-col gap-1 py-3" data-testid="top-up-row">
                      <span className="flex flex-wrap items-baseline justify-between gap-2">
                        <span className="font-mono text-sm break-all" data-testid="top-up-ref">
                          {t.end_to_end_id}
                        </span>
                        <span className="font-medium tabular-nums">{money(t.amount_minor, t.currency)}</span>
                      </span>
                      <span className="text-xs text-zinc-600 dark:text-zinc-400">
                        Le {parisDateTime(t.created_at)} · {orderedBy(t)} · exécution demandée le{" "}
                        {frenchDate(t.requested_execution_date)}
                        {t.file_number ? ` · fichier ${t.file_number}` : ""}
                        {t.status === "cancelled" && t.cancel_reason ? ` · annulé : ${t.cancel_reason}` : ""}
                      </span>
                      <span className="flex flex-wrap items-center gap-2">
                        <Badge tone={TOP_UP_STATUS_TONE[t.status] ?? "neutral"} testId="top-up-status">
                          {TOP_UP_STATUS_LABEL[t.status] ?? t.status}
                        </Badge>
                        {t.cancellable ? (
                          <CancelTopUpOrder transferId={t.transfer_id} reference={t.end_to_end_id} idempotencyKey={randomUUID()} />
                        ) : null}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
              {a.can_generate ? (
                <GenerateTopUpFile accountId={a.bank_account_id} orderedCount={a.ordered_count} idempotencyKey={randomUUID()} />
              ) : null}
              {a.currency !== "EUR" ? <InfoNote>Les fichiers SEPA sont en euros : ce compte n&apos;en produit pas.</InfoNote> : null}
              {a.files.length > 0 ? (
                <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800" data-testid="top-up-files">
                  {[...live, ...past].map((f) => (
                    <TopUpFileRow key={f.id} f={f} />
                  ))}
                </ul>
              ) : null}
            </div>
          );
        })}
      </div>
    </Section>
  );
}

/** An own-account file: status, totals, « Télécharger » (the second time past the warning), « Annuler le fichier ». */
function TopUpFileRow({ f }: { f: TopUpFile }) {
  const href = `/backoffice/reversements/virements/${f.id}/telecharger`;
  const downloadable = ["generated", "downloaded", "sent"].includes(f.status);
  const warning = downloadWarning(f);
  return (
    <li className="flex flex-col gap-2 py-3" data-testid="top-up-file">
      <span className="flex flex-wrap items-center justify-between gap-2">
        <Link href={`/backoffice/reversements/virements/${f.id}`} className="font-medium underline underline-offset-4">
          {f.number}
        </Link>
        <Badge tone={fileStatus(f.status).tone} testId="top-up-file-status">
          {TOP_UP_FILE_STATUS[f.status] ?? f.status}
        </Badge>
      </span>
      <span className="text-sm">
        {f.nb_of_txs} approvisionnement{f.nb_of_txs > 1 ? "s" : ""} · {money(f.ctrl_sum_minor, f.currency)} · exécution le{" "}
        {frenchDate(f.first_execution_date)}
        {f.top_ups_booked > 0 ? ` · ${f.top_ups_booked} crédité${f.top_ups_booked > 1 ? "s" : ""} sur le compte dédié` : ""}
      </span>
      <span className="text-xs text-zinc-600 dark:text-zinc-400">
        Créé le {parisDateTime(f.created_at)} · {f.pain_version}
        {f.closed_at && f.close_reason ? ` · ${f.close_reason}` : ""}
        {f.status === "failed" && f.error ? ` · ${f.error}` : ""}
      </span>
      {warning && downloadable ? (
        <p className="text-sm font-medium text-red-800 dark:text-red-200" data-testid="top-up-download-warning">
          {warning}
        </p>
      ) : null}
      <span className="flex flex-wrap items-center gap-2">
        {downloadable && f.download_count === 0 ? <DownloadLink href={href} label="Télécharger" testId="top-up-file-download" /> : null}
        {downloadable && f.download_count > 0 ? (
          <details data-testid="top-up-file-download-again">
            <summary className="cursor-pointer text-sm underline underline-offset-4">Télécharger de nouveau</summary>
            <p className="mt-2 text-sm">{warning}.</p>
            <DownloadLink
              href={`${href}?confirme=1`}
              label="J'ai compris : télécharger de nouveau"
              testId="top-up-file-download-confirm"
              className={`${inlineButtonClass} mt-2 inline-block`}
            />
          </details>
        ) : null}
        {f.status === "downloaded" ? (
          <ActionForm action={markSent} submitLabel="Marquer comme transmis" buttonClassName={inlineButtonClass} testId="top-up-file-mark-sent">
            <input type="hidden" name="idempotency_key" value={randomUUID()} />
            <input type="hidden" name="file_id" value={f.id} />
            <input type="hidden" name="expected_version" value={f.version} />
          </ActionForm>
        ) : null}
        {fileLive(f.status) && f.top_ups_open > 0 ? (
          <CancelTopUpFile fileId={f.id} number={f.number} idempotencyKey={randomUUID()} />
        ) : null}
      </span>
    </li>
  );
}

/**
 * M2c-6a « Virements » (design §17.3): per paying account, the transfers waiting for a file (with why one would be
 * held today), the cash check, « Générer le fichier » (the sheet states every effect), the files with « Télécharger »
 * (the second time only past a warning), « Marquer comme transmis »; the payee names the bank's verification did not
 * match. Admins and ops managers at aal2 (the database checks it). Nothing is booked before the bank's debit. Review
 * fixes: a generated file whose date passed is « à régénérer », never downloaded (T2); a cancellation asked after
 * download is named until another person confirms it on the file's page (T1); « Nom vérifié » is not offered to who
 * recorded the mismatch, or proposed or confirmed the IBAN (T5).
 */
export default async function TransfersPage() {
  const { supabase } = await staffSession();
  const back = { href: "/backoffice/reversements", label: "Reversements" };
  const { data, error } = await supabase.rpc("transfer_overview");
  if (error || !data) {
    return (
      <WidePage title="Virements" back={back}>
        <InfoNote>Les virements sont réservés aux administrateurs et aux responsables des opérations.</InfoNote>
      </WidePage>
    );
  }
  const o = data as unknown as TransferOverview;
  // M2c-7e-1 (plan §7.4): the own account's top-ups and files
  const { data: topUpData } = await supabase.rpc("top_up_overview");
  const topUps = (topUpData ?? null) as unknown as TopUpOverview | null;
  const busy =
    o.accounts.some((a) => a.files.some((f) => f.status === "pending")) ||
    (topUps?.accounts ?? []).some((a) => a.files.some((f) => f.status === "pending"));
  // M2c-6b-2c (plan §7.4): the last nightly checks found the servicer's share waiting on the dedicated account
  const { data: lastRun } = await supabase
    .from("payment_check_run")
    .select("id")
    .order("started_at", { ascending: false })
    .limit(1);
  const { data: unswept } = lastRun?.[0]
    ? await supabase
        .from("payment_check_result")
        .select("id")
        .eq("run_id", lastRun[0].id)
        .eq("code", "servicer_funds_unswept")
        .limit(1)
    : { data: [] };
  return (
    <WidePage title="Virements" back={back}>
      <AutoRefresh active={busy} abandonable={false} everyMs={2000} maxMs={120_000} />
      <InfoNote>
        Les reversements validés et les remboursements partent par fichier pain.001 : générez-le, téléchargez-le, déposez-le
        dans votre banque, puis « Marquer comme transmis ». Rien n&apos;est comptabilisé avant que le relevé montre le débit.
      </InfoNote>
      {(unswept ?? []).length > 0 ? (
        <p className="text-sm text-amber-900 dark:text-amber-200" data-testid="servicer-funds-unswept">
          {SERVICER_FUNDS_UNSWEPT_NOTE}
        </p>
      ) : null}
      {o.accounts.length === 0 ? <InfoNote>Aucun compte dédié actif.</InfoNote> : null}
      {o.accounts.map((a) => (
        <Account key={a.bank_account_id} a={a} overview={o} />
      ))}
      {/* shown once the servicer has an own account, or owes the dedicated account something to order */}
      {topUps && (topUps.accounts.length > 0 || topUps.needed.some((x) => x.needed_minor !== "0")) ? (
        <TopUpSection o={topUps} />
      ) : null}
      {o.payee_checks.length > 0 ? (
        <Section title="Noms de bénéficiaire non concordants" testId="payee-checks">
          <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
            {o.payee_checks.map((c) => (
              <li key={c.check_id} className="flex flex-col gap-2 py-3" data-testid="payee-check">
                <span className="font-medium">
                  {c.client_name} — {c.holder_name} (IBAN …{c.iban_last4})
                </span>
                <span className="text-sm">
                  {c.result === "no_match" ? "Nom différent" : "Nom proche"}
                  {c.bank_name ? ` (la banque propose « ${c.bank_name} »)` : ""} · {c.note} · signalé le{" "}
                  {parisDateTime(c.recorded_at)}
                  {c.recorded_by ? ` par ${c.recorded_by}` : ""}. Les virements vers ce compte sont bloqués.
                </span>
                {!payeeCheckClearable(c) ? (
                  <span className="text-xs text-zinc-600 dark:text-zinc-400" data-testid="payee-check-other">
                    Une autre personne doit vérifier le titulaire : ni celle qui a signalé le nom, ni celles qui ont proposé ou
                    confirmé cet IBAN.
                  </span>
                ) : (
                  <ActionForm action={clearPayeeMismatch} submitLabel="Nom vérifié" buttonClassName={inlineButtonClass} className="flex flex-wrap items-end gap-2">
                    <input type="hidden" name="idempotency_key" value={randomUUID()} />
                    <input type="hidden" name="check_id" value={c.check_id} />
                    <input name="reason" required maxLength={2000} className={inputClass} aria-label="Comment le titulaire a été vérifié" placeholder="Vérifié avec le client (comment)" />
                  </ActionForm>
                )}
              </li>
            ))}
          </ul>
        </Section>
      ) : null}
    </WidePage>
  );
}
