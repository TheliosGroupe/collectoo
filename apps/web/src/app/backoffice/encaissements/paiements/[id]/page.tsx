import { randomUUID } from "node:crypto";
import Link from "next/link";
import { AutoRefresh } from "@/components/auto-refresh";
import { Badge, InfoNote, Section, Stats, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import {
  APPLIED_ORDER,
  type PaymentDetail,
  REALLOCATE_TEXT,
  allocationRows,
  componentLabel,
  entryLabel,
  liveAllocations,
  notificationText,
  paymentActions,
  paymentStatus,
  positionFigures,
  reverseEffect,
  rowFileLabel,
} from "@/lib/payments/allocation";
import { frenchDate } from "@/lib/payments/bank-accounts";
import { LINK_KIND, REFUND_REASON, REFUND_STATUS, minorToInput, refundReasons, refundable } from "@/lib/payments/debits";
import { METHOD_LABEL, RULE_LABEL, formatRf, reviewReason } from "@/lib/payments/matching";
import { RECEIPT_KIND, type ReceiptVersion, receiptPending, receiptVersions, shortHash } from "@/lib/payments/receipts";
import { money } from "@/lib/payments/statements";
import { Forward, Reallocate, ReleaseHold, ReverseAllocation, UnassignHere, UseForOtherFile } from "./payment-actions";
import { CancelRefund, RequestRefund } from "./refund-actions";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function frenchDateTime(iso: string): string {
  return new Intl.DateTimeFormat("fr-FR", { dateStyle: "short", timeStyle: "short", timeZone: "Europe/Paris" }).format(
    new Date(iso),
  );
}

/**
 * M2b-4 « Paiement » (design §12.3): what was paid, how it was allocated per invoice and component (from the
 * ledger), the notifications recorded for the client (and whether they were sent), and the actions on it for admins
 * and ops managers: reverse an allocation, allocate again, release a held payment on the judge's authorisation,
 * forward to the client, use an overpayment for another file of the debtor. Every action is a command checked in SQL
 * against what this page showed. M2b-5: the receipt (R124-6) and its versions, each PDF with its SHA-256.
 */
export default async function PaymentPage({ params }: PageProps<"/backoffice/encaissements/paiements/[id]">) {
  const { id } = await params;
  const back = { href: "/backoffice/encaissements/a-traiter", label: "Paiements à traiter" };
  const { supabase } = await staffSession();
  const { data } = UUID.test(id) ? await supabase.rpc("payment_detail", { p_payment_id: id }) : { data: null };
  const d = data as unknown as PaymentDetail | null;
  if (!d) {
    return (
      <WidePage title="Paiement" back={back}>
        <InfoNote>Paiement introuvable, ou réservé aux administrateurs et aux responsables des opérations.</InfoNote>
      </WidePage>
    );
  }
  const p = d.payment;
  const cur = p.currency;
  const [{ data: receiptRows }, { data: receiptJobQueued }] = await Promise.all([
    supabase
      .from("receipt")
      .select("id, number, version, kind, known_at, issued_at, pdf_sha256, account_id")
      .eq("payment_id", p.id)
      .order("version", { ascending: false }),
    // whether a receipts job naming this payment is still to run (review #18: the job's outcome ends the wait)
    supabase.rpc("receipt_job_pending", { p_payment_id: p.id }),
  ]);
  const receipts = receiptVersions((receiptRows ?? []) as ReceiptVersion[]);
  const figures = positionFigures(d.position);
  const forwarded = BigInt(figures.forwarded) > BigInt(0);
  const status = paymentStatus(p.status, { forwarded });
  const reason = p.review_reason ? reviewReason(p.review_reason) : null;
  const waiting = (p.status === "matched" || p.status === "partially_allocated") && p.review_reason === null;
  const rows = allocationRows(d.entries);
  const live = liveAllocations(d.entries);
  const actions = paymentActions(d);
  const left = money(d.position.unallocated_minor, cur);
  const docs = d.documents.map((x) => ({ id: x.id, label: `${x.kind} · classé le ${frenchDateTime(x.created_at)}` }));
  const lastAssign = [...d.matches].reverse().find((m) => m.action === "assign");
  // M2b-6: refunds (one pending at a time) and the bank lines linked to this payment (returns, refunds)
  const refunds = d.refunds ?? [];
  const pendingRefund = refunds.find((r) => r.status === "requested") ?? null;
  const bankLines = d.bank_lines ?? [];
  const canRefund = refundable(p, d.position.unallocated_minor);
  const returned = BigInt(d.position.returned_minor) > BigInt(0);
  const anyAction = Object.values(actions).some(Boolean) || canRefund;
  const receiptWaiting = receiptPending({ waitingForAllocation: waiting, jobQueued: receiptJobQueued ?? null });

  return (
    <WidePage title={`Paiement de ${money(p.amount_minor, cur)}`} back={back}>
      <AutoRefresh active={waiting || receiptWaiting} abandonable={false} everyMs={2000} maxMs={5 * 60_000} />
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={status.tone} testId="payment-status">
          {status.label}
        </Badge>
        {reason ? (
          <Badge tone={reason.tone} testId="payment-reason">
            {p.review_reason === "allocation_reversed" ? "Imputation annulée" : reason.label}
          </Badge>
        ) : waiting ? (
          <Badge tone="busy" testId="payment-reason">
            Imputation en cours
          </Badge>
        ) : null}
      </div>
      {reason?.help ? <InfoNote>{reason.help}</InfoNote> : null}
      {pendingRefund ? (
        <InfoNote>
          Remboursement de {money(pendingRefund.amount_minor, cur)} demandé : exécutez le virement dans la banque vers
          l&apos;IBAN …{pendingRefund.payee_iban_end} avec la référence{" "}
          <span className="font-mono font-medium" data-testid="refund-reference">
            {pendingRefund.end_to_end_id}
          </span>
          . Il sera comptabilisé quand son débit apparaîtra sur le relevé.
        </InfoNote>
      ) : null}
      {p.status === "returned" ? (
        <InfoNote>
          La banque a repris ce paiement : ses imputations sont annulées à la date du retour, sa quittance est annulée et
          le client en est informé.
        </InfoNote>
      ) : null}

      <Stats
        items={[
          { label: "Reçu le", value: frenchDate(p.booking_date) },
          { label: "Montant", value: money(p.amount_minor, cur), testId: "payment-amount" },
          { label: "Imputé", value: money(figures.allocated, cur), testId: "payment-allocated" },
          ...(forwarded ? [{ label: "Reversé au client", value: money(figures.forwarded, cur), testId: "payment-forwarded" }] : []),
          { label: "Non imputé", value: left, testId: "payment-unallocated" },
          ...(returned
            ? [{ label: "Ressorti (remboursé ou retourné)", value: money(d.position.returned_minor, cur), testId: "payment-returned" }]
            : []),
        ]}
      />

      <Section title="Virement reçu" testId="payment-bank">
        <dl className="grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
          <div>
            <dt className="text-zinc-600 dark:text-zinc-400">Payeur</dt>
            <dd className="break-words">
              {p.payer_name ?? "Non indiqué"}
              {p.payer_iban_end ? <span className="ml-2 text-xs text-zinc-600 dark:text-zinc-400">IBAN …{p.payer_iban_end}</span> : null}
            </dd>
          </div>
          <div>
            <dt className="text-zinc-600 dark:text-zinc-400">Date de valeur</dt>
            <dd>{frenchDate(p.value_date) || "–"}</dd>
          </div>
          <div className="sm:col-span-2">
            <dt className="text-zinc-600 dark:text-zinc-400">Libellé</dt>
            <dd className="break-words whitespace-pre-line">{p.remittance_text ?? "Sans libellé"}</dd>
          </div>
          {p.creditor_reference ? (
            <div className="sm:col-span-2">
              <dt className="text-zinc-600 dark:text-zinc-400">Référence</dt>
              <dd className="font-mono">{formatRf(p.creditor_reference)}</dd>
            </div>
          ) : null}
        </dl>
      </Section>

      {d.file ? (
        <Section title="Dossier" testId="payment-file">
          <p className="text-sm">
            <Link href={`/backoffice/dossiers/${d.file.account_id}`} className="font-medium underline underline-offset-4">
              {d.file.external_ref}
            </Link>{" "}
            · {d.file.client_name}
            {d.file.debtor_name ? ` · ${d.file.debtor_name}` : ""}
          </p>
          {lastAssign ? (
            <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
              {lastAssign.by_ops
                ? `Affecté par un gestionnaire le ${frenchDateTime(lastAssign.decided_at)}${lastAssign.reason ? ` : ${lastAssign.reason}` : ""}`
                : `${lastAssign.rule ? `Règle ${lastAssign.rule} : ` : ""}${METHOD_LABEL[lastAssign.method] ?? RULE_LABEL[lastAssign.rule ?? ""] ?? lastAssign.method}`}
            </p>
          ) : null}
        </Section>
      ) : null}

      <Section title="Imputation" testId="payment-allocation">
        {rows.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Rien n&apos;est imputé.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="text-left text-xs text-zinc-600 dark:text-zinc-400">
                <tr>
                  <th className="py-1 pr-3 font-normal">Facture ou échéance</th>
                  <th className="py-1 pr-3 font-normal">Composante</th>
                  <th className="py-1 text-right font-normal">Imputé</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.key} className="border-t border-zinc-100 dark:border-zinc-800" data-testid="allocation-row">
                    <td className="py-1.5 pr-3">
                      {r.line.item_ref}
                      {r.line.due_date ? (
                        <span className="block text-xs text-zinc-600 dark:text-zinc-400">échéance {frenchDate(r.line.due_date)}</span>
                      ) : null}
                      {rowFileLabel(r.file, d.file?.external_ref, live.size) ? (
                        <span className="block text-xs" data-testid="allocation-row-file">
                          dossier {rowFileLabel(r.file, d.file?.external_ref, live.size)}
                        </span>
                      ) : null}
                    </td>
                    <td className="py-1.5 pr-3">{componentLabel(r.line.component)}</td>
                    <td className="py-1.5 text-right tabular-nums">{money(r.minor.toString(), cur)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {p.review_reason === "overpayment" && BigInt(d.position.unallocated_minor) > BigInt(0) ? (
          <p className="mt-3 rounded-md bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200" data-testid="overpayment-note">
            Montant non imputé : {left}. Il reste sur le compte de fonds de tiers, n&apos;est jamais reversé au client et sera
            remboursé au payeur, ou imputé sur un autre dossier du débiteur à sa demande écrite.
          </p>
        ) : null}
        <p className="mt-3 text-xs text-zinc-600 dark:text-zinc-400" data-testid="applied-order">
          {APPLIED_ORDER}
        </p>
      </Section>

      <Section title="Quittance" testId="payment-receipt">
        {receipts.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">
            {p.account_id === null
              ? "Pas de quittance : aucun dossier n'est rattaché à ce paiement."
              : "Quittance en cours d'établissement (après l'imputation)."}
          </p>
        ) : (
          <ul className="flex flex-col gap-2 text-sm">
            {receipts.map((r) => (
              <li
                key={r.id}
                className="flex flex-wrap items-baseline justify-between gap-2 border-t border-zinc-100 pt-2 first:border-0 first:pt-0 dark:border-zinc-800"
                data-testid="receipt-version"
              >
                <span>
                  <span className="font-medium">{r.number}</span> · {r.label}
                  <span className="ml-2 inline-flex gap-1 align-middle">
                    <Badge tone={(RECEIPT_KIND[r.kind] ?? RECEIPT_KIND.update).tone}>
                      {(RECEIPT_KIND[r.kind] ?? { label: r.kind }).label}
                    </Badge>
                    {r.current ? <Badge tone="neutral">En vigueur</Badge> : null}
                  </span>
                  <span className="block text-xs text-zinc-600 dark:text-zinc-400">
                    établie le {frenchDateTime(r.known_at)} · SHA-256 <span className="font-mono">{shortHash(r.pdf_sha256)}</span>
                  </span>
                </span>
                <a
                  href={`/backoffice/quittances/${r.id}`}
                  className="underline underline-offset-4"
                  data-testid="receipt-pdf"
                  aria-label={`Quittance ${r.number}, version ${r.version} (PDF)`}
                >
                  PDF
                </a>
              </li>
            ))}
          </ul>
        )}
        {receiptWaiting && receipts.length > 0 ? (
          <p className="mt-2 text-xs text-zinc-600 dark:text-zinc-400" data-testid="receipt-pending">
            Nouvelle version en cours d&apos;établissement.
          </p>
        ) : null}
        <p className="mt-3 text-xs text-zinc-600 dark:text-zinc-400">
          Établie à partir de la comptabilité, sans solde restant dû avant le calcul des intérêts ; le payeur n&apos;y est
          nommé que s&apos;il est partie au dossier. Envoi au débiteur : à venir.
        </p>
      </Section>

      {refunds.length > 0 || bankLines.length > 0 ? (
        <Section title="Remboursements et retours" testId="payment-money-out">
          <ul className="flex flex-col gap-2 text-sm">
            {refunds.map((r) => (
              <li
                key={r.id}
                className="flex flex-wrap items-start justify-between gap-2 border-t border-zinc-100 pt-2 first:border-0 first:pt-0 dark:border-zinc-800"
                data-testid="refund-row"
              >
                <span className="min-w-0">
                  <span className="font-medium">Remboursement {money(r.amount_minor, cur)}</span>{" "}
                  <Badge tone={(REFUND_STATUS[r.status] ?? REFUND_STATUS.requested).tone}>
                    {(REFUND_STATUS[r.status] ?? { label: r.status }).label}
                  </Badge>
                  <span className="block text-xs text-zinc-600 dark:text-zinc-400">
                    {REFUND_REASON[r.reason_code]?.label ?? r.reason_code} · à {r.payee_name} (IBAN …{r.payee_iban_end}
                    {r.payee_is_payer ? ", celui du payeur" : ", autre compte"}) · référence{" "}
                    <span className="font-mono">{r.end_to_end_id}</span>
                  </span>
                  <span className="block text-xs text-zinc-600 dark:text-zinc-400">
                    Demandé le {frenchDateTime(r.requested_at)}
                    {r.executed_on ? ` · débité le ${frenchDate(r.executed_on)}` : ""}
                    {r.cancelled_at ? ` · annulé le ${frenchDateTime(r.cancelled_at)} (${r.cancel_reason ?? ""})` : ""}
                  </span>
                  <span className="block text-xs text-zinc-600 dark:text-zinc-400">Motif interne : {r.reason}</span>
                </span>
                {r.status === "requested" ? (
                  <CancelRefund paymentId={p.id} refundId={r.id} reference={r.end_to_end_id} idempotencyKey={randomUUID()} />
                ) : null}
              </li>
            ))}
            {bankLines.map((l) => (
              <li
                key={l.bank_transaction_id}
                className="border-t border-zinc-100 pt-2 first:border-0 first:pt-0 dark:border-zinc-800"
                data-testid="bank-line-row"
              >
                <span className="font-medium">{LINK_KIND[l.kind] ?? l.kind}</span> ·{" "}
                {l.direction === "debit" ? "−" : "+"} {money(l.amount_minor, cur)} au {frenchDate(l.booking_date)}
                {l.return_reason ? ` · motif bancaire ${l.return_reason}` : ""}
                <span className="block text-xs text-zinc-600 dark:text-zinc-400">
                  {l.method === "auto" ? "Rapproché automatiquement" : "Rapproché par un gestionnaire"} le{" "}
                  {frenchDateTime(l.decided_at)}
                  {l.reason ? ` · ${l.reason}` : ""} ·{" "}
                  <Link href={`/backoffice/encaissements/releves/${l.statement_id}`} className="underline underline-offset-4">
                    relevé
                  </Link>
                </span>
              </li>
            ))}
          </ul>
        </Section>
      ) : null}

      {anyAction ? (
        <Section title="Actions" testId="payment-actions">
          <div className="flex flex-col gap-3">
            {[...live.entries()].map(([account, entries]) => {
              const total = entries.reduce((s, e) => s + BigInt(e.amount_minor ?? "0"), BigInt(0));
              const fileRef = entries[0].external_ref ?? "";
              return (
                <ReverseAllocation
                  key={account}
                  paymentId={p.id}
                  accountId={account}
                  fileRef={fileRef}
                  effect={reverseEffect({
                    amount: money(total.toString(), cur),
                    fileRef,
                    ownFile: account === p.account_id,
                    othersRemain: live.size > 1,
                  })}
                  entryIds={entries.map((e) => e.entry_id)}
                  idempotencyKey={randomUUID()}
                />
              );
            })}
            {actions.allocate && p.review_reason ? (
              <Reallocate
                paymentId={p.id}
                reason={p.review_reason}
                effect={REALLOCATE_TEXT[p.review_reason] ?? ""}
                idempotencyKey={randomUUID()}
              />
            ) : null}
            {actions.releaseHold ? <ReleaseHold paymentId={p.id} docs={docs} idempotencyKey={randomUUID()} /> : null}
            {actions.forward && d.file ? (
              <Forward
                paymentId={p.id}
                left={left}
                leftMinor={d.position.unallocated_minor}
                client={d.file.client_name}
                docs={docs}
                idempotencyKey={randomUUID()}
              />
            ) : null}
            {actions.otherFile && p.review_reason ? (
              <UseForOtherFile
                paymentId={p.id}
                reason={p.review_reason}
                left={left}
                files={d.other_files}
                docs={docs}
                idempotencyKey={randomUUID()}
              />
            ) : null}
            {canRefund ? (
              <RequestRefund
                paymentId={p.id}
                left={left}
                leftInput={minorToInput(d.position.unallocated_minor)}
                leftMinor={d.position.unallocated_minor}
                reviewReason={p.review_reason}
                reasons={refundReasons(p.status, p.review_reason)}
                payerName={p.payer_name}
                payerIbanEnd={p.payer_iban_end}
                payerIbanValid={p.payer_iban_valid ?? false}
                idempotencyKey={randomUUID()}
              />
            ) : null}
            {actions.unassign ? <UnassignHere paymentId={p.id} idempotencyKey={randomUUID()} /> : null}
          </div>
        </Section>
      ) : null}

      <Section title="Écritures" testId="payment-entries">
        {d.entries.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucune écriture propre à ce paiement (l&apos;encaissement du jour est comptabilisé à l&apos;import).</p>
        ) : (
          <ul className="flex flex-col gap-2 text-sm">
            {d.entries.map((e) => (
              <li key={e.entry_id} className="flex flex-wrap items-baseline justify-between gap-2 border-t border-zinc-100 pt-2 first:border-0 first:pt-0 dark:border-zinc-800" data-testid="payment-entry">
                <span>
                  {entryLabel(e)}
                  {e.external_ref ? ` · ${e.external_ref}` : ""} · au {frenchDate(e.effective_date)}
                  {e.reversed_by ? <span className="ml-2 text-xs text-zinc-600 dark:text-zinc-400">(annulée)</span> : null}
                  {e.reason ? <span className="block text-xs text-zinc-600 dark:text-zinc-400">{e.reason}</span> : null}
                  {e.ops_note ? (
                    <span className="block text-xs text-zinc-600 dark:text-zinc-400" data-testid="entry-ops-note">
                      Motif interne : {e.ops_note}
                    </span>
                  ) : null}
                </span>
                <span className="tabular-nums">{money(e.amount_minor, cur)}</span>
              </li>
            ))}
          </ul>
        )}
      </Section>

      <Section title="Information du client" testId="payment-notifications">
        {d.notifications.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucune notification pour le client pour l&apos;instant.</p>
        ) : (
          <ul className="flex flex-col gap-1 text-sm">
            {d.notifications.map((n, i) => (
              <li key={i}>{notificationText(n, frenchDateTime)}</li>
            ))}
          </ul>
        )}
      </Section>

      {d.matches.length > 0 ? (
        <Section title="Historique du rapprochement" testId="payment-matches">
          <ul className="flex flex-col gap-1 text-sm">
            {d.matches.map((m, i) => (
              <li key={i}>
                {m.action === "assign" ? "Affecté à" : "Désaffecté de"} {m.external_ref} ·{" "}
                {m.by_ops ? "gestionnaire" : `règle ${m.rule ?? ""}`} · {frenchDateTime(m.decided_at)}
                {m.reason ? <span className="block text-xs text-zinc-600 dark:text-zinc-400">{m.reason}</span> : null}
              </li>
            ))}
          </ul>
        </Section>
      ) : null}
    </WidePage>
  );
}
