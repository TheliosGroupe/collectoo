import { randomUUID } from "node:crypto";
import Link from "next/link";
import { AutoRefresh } from "@/components/auto-refresh";
import { Badge, InfoNote, Section, Stats, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import {
  type AccountDetail,
  HOLD_LABEL,
  blockingHold,
  componentLabel,
  groupsOfFour,
  itemBalances,
  paymentStatus,
  proposalSummary,
} from "@/lib/payments/allocation";
import { frenchDate } from "@/lib/payments/bank-accounts";
import { DIRECT_REFUSAL, DIRECT_STATUS } from "@/lib/payments/debits";
import { reviewReason } from "@/lib/payments/matching";
import { money } from "@/lib/payments/statements";
import { ApplyCreditNote } from "./credit-note";
import { RecordDirectPayment } from "./direct-payment";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const ACCOUNT_STATUS: Record<string, string> = {
  awaiting_first_letter: "En attente du premier courrier",
  in_collection: "En recouvrement",
  arrangement: "Échéancier",
  legal: "Procédure",
  on_hold: "Suspendu",
  closed_paid: "Clôturé (payé)",
  closed_settled: "Clôturé (transigé)",
  closed_uncollectable: "Clôturé (irrécouvrable)",
  closed_recalled: "Clôturé (rappelé par le client)",
};

/**
 * M2b-4 « Dossier » (design §12.4, minimal, read-only): reference, client, debtor, RF reference, balances per
 * item and component from the ledger, holds, payments; and « Appliquer l'avoir » when the engine proposes to apply
 * a credit note (founder #7: compensation must be invoked, one tap). Staff who read the portfolio; actions for
 * admins and ops managers. M2b-5: each payment's receipt (its latest version, PDF).
 */
export default async function FilePage({ params }: PageProps<"/backoffice/dossiers/[id]">) {
  const { id } = await params;
  const back = { href: "/backoffice/encaissements/a-traiter", label: "Paiements à traiter" };
  const { supabase } = await staffSession();
  const { data } = UUID.test(id) ? await supabase.rpc("account_detail", { p_account_id: id }) : { data: null };
  const d = data as unknown as AccountDetail | null;
  if (!d) {
    return (
      <WidePage title="Dossier" back={back}>
        <InfoNote>Dossier introuvable, ou hors de vos portefeuilles.</InfoNote>
      </WidePage>
    );
  }
  const a = d.account;
  const cur = a.currency;
  const fmt = (minor: string) => money(minor, cur);
  const { items, total } = itemBalances(d.balances);
  const debtor = d.parties.find((p) => p.role === "borrower")?.name ?? d.parties[0]?.name ?? "";
  const held = blockingHold(d.holds);
  // M2b-5: each payment's receipt as it stands (its latest version), read under RLS
  const { data: receiptRows } = d.payments.length
    ? await supabase
        .from("receipt")
        .select("id, payment_id, number, version, kind")
        .in(
          "payment_id",
          d.payments.map((p) => p.id),
        )
        .order("version", { ascending: false })
    : { data: [] };
  const receiptOf = new Map<string, { id: string; number: string; version: number; kind: string }>();
  for (const r of receiptRows ?? []) if (!receiptOf.has(r.payment_id)) receiptOf.set(r.payment_id, r);
  // M2b-6: payments the debtor made to the client directly (declared from the client's statement)
  const direct = d.direct_payments ?? [];
  const directWaiting = direct.some((x) => x.status === "requested");
  const docs = (d.documents ?? []).map((x) => ({
    id: x.id,
    label: `${x.kind} · classé le ${frenchDate(x.created_at.slice(0, 10))}`,
  }));
  const itemChoices = items.filter((it) => it.kind !== "credit_note").map((it) => ({ id: it.id, ref: it.ref }));
  const today = new Intl.DateTimeFormat("fr-CA", { timeZone: "Europe/Paris" }).format(new Date());

  return (
    <WidePage title={`Dossier ${a.external_ref}`} back={back}>
      <AutoRefresh active={directWaiting} abandonable={false} everyMs={2000} maxMs={60_000} />
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={a.status.startsWith("closed") ? "neutral" : "ok"} testId="file-status">
          {ACCOUNT_STATUS[a.status] ?? a.status}
        </Badge>
        {d.holds.map((h) => (
          <Badge key={h.kind} tone="error" testId="file-hold">
            {HOLD_LABEL[h.kind] ?? h.kind}
          </Badge>
        ))}
      </div>
      <Stats
        items={[
          { label: "Client", value: a.client_name },
          { label: "Débiteur", value: debtor || "–" },
          { label: "Solde du dossier", value: fmt(total.toString()), testId: "file-balance" },
          { label: "Reprise au", value: frenchDate(a.servicing_start) || "–" },
        ]}
      />
      {d.rf ? (
        <p className="text-sm">
          Référence de paiement : <span className="font-mono" data-testid="file-rf">{groupsOfFour(d.rf)}</span>
        </p>
      ) : null}
      <InfoNote>
        Soldes tenus par la comptabilité à ce jour. Les intérêts de retard et indemnités ne sont pas encore calculés : aucun
        solde restant dû n&apos;est communiqué au débiteur avant ce calcul.
      </InfoNote>

      {d.proposal ? (
        <Section title="Avoir à appliquer" testId="file-credit-note">
          <p className="text-sm">{proposalSummary(d.proposal, fmt, frenchDate)}</p>
          {held ? (
            <p className="mt-3 text-sm text-amber-900 dark:text-amber-200" data-testid="credit-note-held">
              Dossier bloqué (surendettement ou procédure collective) : la compensation n&apos;est pas invoquée tant que le
              blocage est en place.
            </p>
          ) : d.can_act ? (
            <div className="mt-3">
              <ApplyCreditNote
                accountId={a.id}
                proposalKey={d.proposal.proposal_key}
                summary={proposalSummary(d.proposal, fmt, frenchDate)}
                idempotencyKey={randomUUID()}
              />
            </div>
          ) : null}
        </Section>
      ) : null}

      <Section title="Créances" testId="file-items">
        {items.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun solde comptabilisé.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="text-left text-xs text-zinc-600 dark:text-zinc-400">
                <tr>
                  <th className="py-1 pr-3 font-normal">Pièce</th>
                  <th className="py-1 pr-3 font-normal">Composante</th>
                  <th className="py-1 text-right font-normal">Solde</th>
                </tr>
              </thead>
              <tbody>
                {items.flatMap((it) =>
                  it.components.map((c, i) => (
                    <tr key={`${it.id}:${c.component}`} className="border-t border-zinc-100 dark:border-zinc-800" data-testid="file-item">
                      <td className="py-1.5 pr-3">
                        {i === 0 ? (
                          <>
                            {it.ref}
                            <span className="block text-xs text-zinc-600 dark:text-zinc-400">
                              {it.kind === "credit_note" ? "avoir" : it.due ? `échéance ${frenchDate(it.due)}` : ""}
                            </span>
                          </>
                        ) : null}
                      </td>
                      <td className="py-1.5 pr-3">{componentLabel(c.component)}</td>
                      <td className="py-1.5 text-right tabular-nums">{fmt(c.minor.toString())}</td>
                    </tr>
                  )),
                )}
              </tbody>
            </table>
          </div>
        )}
      </Section>

      <Section title="Paiements" testId="file-payments">
        {d.payments.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun paiement reçu pour ce dossier.</p>
        ) : (
          <ul className="flex flex-col gap-2 text-sm">
            {d.payments.map((p) => {
              const s = paymentStatus(p.status, { forwarded: p.forwarded });
              const receipt = receiptOf.get(p.id);
              return (
                <li key={p.id} className="flex flex-wrap items-center justify-between gap-2" data-testid="file-payment">
                  {d.can_act ? (
                    <Link href={`/backoffice/encaissements/paiements/${p.id}`} className="underline underline-offset-4">
                      {money(p.amount_minor, p.currency)} reçu le {frenchDate(p.booking_date)}
                    </Link>
                  ) : (
                    <span>
                      {money(p.amount_minor, p.currency)} reçu le {frenchDate(p.booking_date)}
                    </span>
                  )}
                  <span className="flex flex-wrap items-center gap-1">
                    <Badge tone={s.tone}>{s.label}</Badge>
                    {p.review_reason ? <Badge tone={reviewReason(p.review_reason).tone}>{reviewReason(p.review_reason).label}</Badge> : null}
                    {receipt ? (
                      <a
                        href={`/backoffice/quittances/${receipt.id}`}
                        className="text-xs underline underline-offset-4"
                        data-testid="file-payment-receipt"
                      >
                        Quittance {receipt.number} v{receipt.version}
                        {receipt.kind === "void" ? " (annulée)" : ""}
                      </a>
                    ) : null}
                  </span>
                </li>
              );
            })}
          </ul>
        )}
      </Section>

      {direct.length > 0 || d.can_act ? (
        <Section title="Paiements reçus directement par le client" testId="file-direct-payments">
          {direct.length === 0 ? (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun paiement direct déclaré.</p>
          ) : (
            <ul className="flex flex-col gap-2 text-sm">
              {direct.map((x) => (
                <li key={x.id} className="border-t border-zinc-100 pt-2 first:border-0 first:pt-0 dark:border-zinc-800" data-testid="direct-payment-row">
                  <span className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">
                      {money(x.amount_minor, x.currency)} payés le {frenchDate(x.paid_on)}
                    </span>
                    <Badge tone={(DIRECT_STATUS[x.status] ?? DIRECT_STATUS.requested).tone} testId="direct-payment-status">
                      {(DIRECT_STATUS[x.status] ?? { label: x.status }).label}
                    </Badge>
                  </span>
                  {x.refusal_code ? (
                    <span className="block text-xs text-red-800 dark:text-red-300">{DIRECT_REFUSAL[x.refusal_code] ?? x.refusal_code}</span>
                  ) : null}
                  {x.items.length > 0 ? (
                    <span className="block text-xs text-zinc-600 dark:text-zinc-400">Factures désignées : {x.items.join(", ")}</span>
                  ) : null}
                  {x.lines.length > 0 ? (
                    <span className="block text-xs text-zinc-600 dark:text-zinc-400" data-testid="direct-payment-lines">
                      Imputé : {x.lines.map((l) => `${l.item_ref} ${componentLabel(l.component).toLowerCase()} ${money(l.amount_minor, x.currency)}`).join(" · ")}
                    </span>
                  ) : null}
                  {x.reason ? <span className="block text-xs text-zinc-600 dark:text-zinc-400">Motif interne : {x.reason}</span> : null}
                </li>
              ))}
            </ul>
          )}
          {d.can_act && a.status !== "staged" && !a.status.startsWith("closed") ? (
            <div className="mt-3">
              <RecordDirectPayment accountId={a.id} items={itemChoices} docs={docs} today={today} idempotencyKey={randomUUID()} />
            </div>
          ) : null}
        </Section>
      ) : null}
    </WidePage>
  );
}
