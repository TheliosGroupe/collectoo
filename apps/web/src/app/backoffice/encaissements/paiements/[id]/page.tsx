import { randomUUID } from "node:crypto";
import Link from "next/link";
import { AutoRefresh } from "@/components/auto-refresh";
import { Badge, InfoNote, Section, Stats, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import {
  ENTRY_LABEL,
  NOTIFICATION_LABEL,
  type PaymentDetail,
  REALLOCATE_TEXT,
  allocationRows,
  componentLabel,
  liveAllocations,
  paymentActions,
  paymentStatus,
} from "@/lib/payments/allocation";
import { frenchDate } from "@/lib/payments/bank-accounts";
import { METHOD_LABEL, RULE_LABEL, formatRf, reviewReason } from "@/lib/payments/matching";
import { money } from "@/lib/payments/statements";
import { Forward, Reallocate, ReleaseHold, ReverseAllocation, UnassignHere, UseForOtherFile } from "./payment-actions";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function frenchDateTime(iso: string): string {
  return new Intl.DateTimeFormat("fr-FR", { dateStyle: "short", timeStyle: "short", timeZone: "Europe/Paris" }).format(
    new Date(iso),
  );
}

/**
 * M2b-4 « Paiement » (design §12.3): what was paid, how it was allocated per invoice and component (from the
 * ledger), what the client was told, and the actions on it for admins and ops managers: reverse an allocation,
 * allocate again, release a held payment on the judge's authorisation, forward to the client, use an overpayment
 * for another file of the debtor. Every action is a command checked in SQL against what this page showed.
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
  const status = paymentStatus(p.status);
  const reason = p.review_reason ? reviewReason(p.review_reason) : null;
  const waiting = (p.status === "matched" || p.status === "partially_allocated") && p.review_reason === null;
  const rows = allocationRows(d.entries);
  const live = liveAllocations(d.entries);
  const actions = paymentActions(d);
  const left = money(d.position.unallocated_minor, cur);
  const docs = d.documents.map((x) => ({ id: x.id, label: `${x.kind} · classé le ${frenchDateTime(x.created_at)}` }));
  const lastAssign = [...d.matches].reverse().find((m) => m.action === "assign");
  const anyAction = Object.values(actions).some(Boolean);

  return (
    <WidePage title={`Paiement de ${money(p.amount_minor, cur)}`} back={back}>
      <AutoRefresh active={waiting} abandonable={false} everyMs={2000} maxMs={5 * 60_000} />
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

      <Stats
        items={[
          { label: "Reçu le", value: frenchDate(p.booking_date) },
          { label: "Montant", value: money(p.amount_minor, cur), testId: "payment-amount" },
          { label: "Imputé", value: money(d.position.allocated_minor, cur), testId: "payment-allocated" },
          { label: "Non imputé", value: left, testId: "payment-unallocated" },
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
                      {live.size > 1 && r.file ? <span className="block text-xs">dossier {r.file}</span> : null}
                    </td>
                    <td className="py-1.5 pr-3">{componentLabel(r.line.component)}</td>
                    <td className="py-1.5 text-right tabular-nums">{money(r.minor.toString(), cur)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {BigInt(d.position.unallocated_minor) > BigInt(0) && BigInt(d.position.allocated_minor) > BigInt(0) ? (
          <p className="mt-3 rounded-md bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200" data-testid="overpayment-note">
            Montant non imputé : {left}. Il reste sur le compte de fonds de tiers, n&apos;est jamais reversé au client et sera
            remboursé au payeur, ou imputé sur un autre dossier du débiteur à sa demande écrite.
          </p>
        ) : null}
        <p className="mt-3 text-xs text-zinc-600 dark:text-zinc-400">
          Ordre légal : factures désignées par le débiteur, puis factures échues de la plus ancienne à la plus récente (au
          prorata à date égale), puis factures non échues ; dans chaque facture, intérêts avant principal (art. 1342-10 et
          1343-1 C. civ.).
        </p>
      </Section>

      {anyAction ? (
        <Section title="Actions" testId="payment-actions">
          <div className="flex flex-col gap-3">
            {[...live.entries()].map(([account, entries]) => {
              const total = entries.reduce((s, e) => s + BigInt(e.amount_minor ?? "0"), BigInt(0));
              return (
                <ReverseAllocation
                  key={account}
                  paymentId={p.id}
                  accountId={account}
                  fileRef={entries[0].external_ref ?? ""}
                  amount={money(total.toString(), cur)}
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
                  {ENTRY_LABEL[e.entry_type] ?? e.entry_type}
                  {e.external_ref ? ` · ${e.external_ref}` : ""} · au {frenchDate(e.effective_date)}
                  {e.reversed_by ? <span className="ml-2 text-xs text-zinc-600 dark:text-zinc-400">(annulée)</span> : null}
                  {e.reason ? <span className="block text-xs text-zinc-600 dark:text-zinc-400">{e.reason}</span> : null}
                </span>
                <span className="tabular-nums">{money(e.amount_minor, cur)}</span>
              </li>
            ))}
          </ul>
        )}
      </Section>

      <Section title="Client informé (art. R124-5 CPCE)" testId="payment-notifications">
        {d.notifications.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Rien à signaler au client pour l&apos;instant.</p>
        ) : (
          <ul className="flex flex-col gap-1 text-sm">
            {d.notifications.map((n, i) => (
              <li key={i}>
                {NOTIFICATION_LABEL[n.kind] ?? n.kind} · {n.client_name} · {frenchDateTime(n.created_at)}
              </li>
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
