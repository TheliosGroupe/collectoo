import { randomUUID } from "node:crypto";
import Link from "next/link";
import { Badge, InfoNote, Section, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { frenchDate } from "@/lib/payments/bank-accounts";
import { DEBIT_REVIEW, LINK_KIND, lineKindLabel, returnEffect } from "@/lib/payments/debits";
import { money, signedMoney } from "@/lib/payments/statements";
import { Explain, LinkRefund, LinkReturn, ResolveDuplicate } from "./debit-actions";

const PAGE_SIZE = 20;
const TABS: Record<string, string> = {
  "a-classer": "À classer",
  doublons: "Doublons possibles",
  frais: "Frais et autres débits",
  traites: "Traités",
};

type Row = {
  bank_transaction_id: string;
  statement_id: string;
  direction: string;
  kind: string;
  amount_minor: string;
  currency: string;
  booking_date: string;
  age_days: number;
  counterparty_name: string | null;
  counterparty_iban_end: string | null;
  remittance_text: string | null;
  end_to_end_id: string | null;
  original_end_to_end_id: string | null;
  return_reason: string | null;
  review_reason: string | null;
  candidates: Candidate[];
  decision: string | null;
  decided_at: string | null;
  decided_payment_id: string | null;
  total: number;
};
type Candidate = {
  payment_id?: string;
  refund_request_id?: string;
  amount_minor?: string;
  booking_date?: string;
  payer_name?: string | null;
  left_minor?: string;
  file_reference?: string | null;
  status?: string;
  end_to_end_id?: string;
  refund_status?: string;
  refund_minor?: string;
};
type Options = {
  payments: { payment_id: string; amount_minor: string; booking_date: string; payer_name: string | null; left_minor: string; file_reference: string | null }[];
  refunds: { refund_request_id: string; amount_minor: string; end_to_end_id: string; status: string; payee_name: string }[];
};

/**
 * M2b-6 « Débits et retours » (design §12): what leaves the client-funds account, phone-first. Lines the debit job
 * could not link (a payment's return, our refund, a refund come back), with what it found and the payments ops may
 * choose; CSV lines held as suspected duplicates; fees and other debits (not booked in M2b: explained gaps, founder
 * #20); lines decided. Every action is a SQL command that checks again what this page showed. Admins and ops managers.
 */
export default async function DebitsPage({ searchParams }: PageProps<"/backoffice/encaissements/debits">) {
  const query = await searchParams;
  const tab = typeof query.onglet === "string" && query.onglet in TABS ? query.onglet : "a-classer";
  const page = Math.max(1, Number.parseInt(typeof query.page === "string" ? query.page : "1", 10) || 1);
  const { supabase, claims } = await staffSession();
  const back = { href: "/backoffice/encaissements", label: "Relevés bancaires" };
  const { data: memberships } = await supabase
    .from("membership")
    .select("role, organization:organization_id(kind)")
    .eq("user_id", claims.sub ?? "");
  const staff = (memberships ?? []).find((m) => m.organization?.kind === "servicer");
  if (!(staff?.role === "admin" || staff?.role === "ops_manager")) {
    return (
      <WidePage title="Débits et retours" back={back}>
        <InfoNote>Les lignes bancaires sont réservées aux administrateurs et aux responsables des opérations.</InfoNote>
      </WidePage>
    );
  }
  const { data } = await supabase.rpc("debit_queue", { p_tab: tab, p_offset: (page - 1) * PAGE_SIZE, p_limit: PAGE_SIZE });
  const rows = (data ?? []) as unknown as Row[];
  const total = rows[0]?.total ?? 0;
  // what ops may link a line to when the job found nothing it could link (bounded: one keyed read per line shown)
  const options = new Map<string, Options>();
  if (tab === "a-classer") {
    const reads = await Promise.all(
      rows.map((r) => supabase.rpc("debit_link_options", { p_bank_transaction_id: r.bank_transaction_id })),
    );
    rows.forEach((r, i) => options.set(r.bank_transaction_id, (reads[i].data ?? { payments: [], refunds: [] }) as unknown as Options));
  }
  const href = (t: string, p = 1) => `/backoffice/encaissements/debits?onglet=${t}${p > 1 ? `&page=${p}` : ""}`;

  return (
    <WidePage title="Débits et retours" back={back}>
      <InfoNote>
        Un retour de la banque annule les imputations du paiement à la date du retour et informe le client ; un
        remboursement n&apos;est comptabilisé qu&apos;une fois son débit sur le relevé. Les frais bancaires ne sont pas
        comptabilisés sur le compte de fonds de tiers : ils restent des écarts expliqués.
      </InfoNote>
      <nav className="flex flex-wrap gap-2 text-sm" aria-label="Onglets">
        {Object.entries(TABS).map(([key, label]) => (
          <Link
            key={key}
            href={href(key)}
            aria-current={key === tab ? "page" : undefined}
            className={`rounded-full border px-3 py-1 ${
              key === tab
                ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                : "border-zinc-300 dark:border-zinc-700"
            }`}
          >
            {label}
            {key === tab ? ` (${total})` : ""}
          </Link>
        ))}
      </nav>

      <Section title={TABS[tab]} testId="debit-list">
        {rows.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucune ligne.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows.map((r) => (
              <li key={r.bank_transaction_id} className="flex flex-col gap-2 py-3" data-testid="debit-row">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="flex flex-wrap items-center gap-2">
                    <Badge tone="neutral">{lineKindLabel(r.kind, r.direction)}</Badge>
                    {tab !== "traites" ? <Badge tone={r.age_days >= 3 ? "action" : "neutral"}>J+{r.age_days}</Badge> : null}
                    {r.decision ? <Badge tone="ok">{LINK_KIND[r.decision] ?? r.decision}</Badge> : null}
                  </span>
                  <span
                    className={`font-medium tabular-nums ${r.direction === "debit" ? "text-red-800 dark:text-red-300" : ""}`}
                    data-testid="debit-amount"
                  >
                    {signedMoney(r.direction, r.amount_minor, r.currency)}
                  </span>
                </div>
                <p className="text-sm">
                  {frenchDate(r.booking_date)} · {r.counterparty_name ?? "Contrepartie non indiquée"}
                  {r.counterparty_iban_end ? ` · IBAN …${r.counterparty_iban_end}` : ""}
                </p>
                {r.remittance_text ? (
                  <p className="text-sm break-words text-zinc-600 dark:text-zinc-400">{r.remittance_text}</p>
                ) : null}
                <p className="font-mono text-xs break-all text-zinc-600 dark:text-zinc-400">
                  {r.original_end_to_end_id ? `Réf. d'origine ${r.original_end_to_end_id}` : r.end_to_end_id ? `Réf. ${r.end_to_end_id}` : "Sans référence"}
                  {r.return_reason ? ` · motif ${r.return_reason}` : ""} ·{" "}
                  <Link href={`/backoffice/encaissements/releves/${r.statement_id}`} className="underline underline-offset-4">
                    relevé
                  </Link>
                </p>
                {r.review_reason ? (
                  <p className="text-sm text-amber-900 dark:text-amber-200" data-testid="debit-review">
                    {DEBIT_REVIEW[r.review_reason] ?? r.review_reason}
                  </p>
                ) : null}
                {tab === "a-classer" ? <LineActions row={r} options={options.get(r.bank_transaction_id)} /> : null}
                {tab === "doublons" ? (
                  <ResolveDuplicate
                    lineId={r.bank_transaction_id}
                    releaseEffect={
                      r.direction === "credit"
                        ? `La ligne deviendra un paiement reçu de ${money(r.amount_minor, r.currency)} : comptabilisé sur le compte de fonds de tiers à la date du relevé, puis rapproché d'un dossier.`
                        : "La ligne sera classée comme un débit à traiter (retour, remboursement ou frais)."
                    }
                    idempotencyKey={randomUUID()}
                  />
                ) : null}
                {tab === "traites" && r.decided_payment_id ? (
                  <Link href={`/backoffice/encaissements/paiements/${r.decided_payment_id}`} className="text-sm underline underline-offset-4">
                    Voir le paiement
                  </Link>
                ) : null}
              </li>
            ))}
          </ul>
        )}
        {total > PAGE_SIZE ? (
          <nav className="mt-3 flex items-center justify-between gap-3 text-sm" aria-label="Pages">
            {page > 1 ? <Link href={href(tab, page - 1)}>← Précédentes</Link> : <span />}
            <span className="text-zinc-600 dark:text-zinc-400">
              {(page - 1) * PAGE_SIZE + 1}–{Math.min(page * PAGE_SIZE, total)} sur {total}
            </span>
            {page * PAGE_SIZE < total ? <Link href={href(tab, page + 1)}>Suivantes →</Link> : <span />}
          </nav>
        ) : null}
        {tab === "frais" ? (
          <p className="mt-3 text-xs text-zinc-600 dark:text-zinc-400">
            Non comptabilisés : demandez à la banque d&apos;imputer ses frais sur le compte d&apos;exploitation.
          </p>
        ) : null}
      </Section>
    </WidePage>
  );
}

/** One line's actions: the payments and refunds the job found, those of the same amount on the account, explain. */
function LineActions({ row, options }: { row: Row; options: Options | undefined }) {
  const cur = row.currency;
  const fromReview = row.candidates.filter((c) => c.payment_id && !c.refund_request_id && c.left_minor);
  const payments = new Map<string, { payment_id: string; amount_minor: string; booking_date: string; payer_name: string | null; left_minor: string; file_reference: string | null }>();
  for (const c of fromReview)
    payments.set(c.payment_id!, {
      payment_id: c.payment_id!,
      amount_minor: c.amount_minor ?? "0",
      booking_date: c.booking_date ?? "",
      payer_name: c.payer_name ?? null,
      left_minor: c.left_minor!,
      file_reference: c.file_reference ?? null,
    });
  for (const p of options?.payments ?? []) if (!payments.has(p.payment_id)) payments.set(p.payment_id, p);
  const refunds = options?.refunds ?? [];
  const isReturn = row.direction === "debit" && row.kind !== "refund_out";
  return (
    <div className="flex flex-col gap-2">
      {row.direction === "debit"
        ? [...payments.values()]
            .filter((p) => BigInt(p.left_minor) >= BigInt(row.amount_minor))
            .slice(0, isReturn ? 5 : 2)
            .map((p) => {
              const full = BigInt(p.left_minor) === BigInt(row.amount_minor);
              return (
                <LinkReturn
                  key={p.payment_id}
                  lineId={row.bank_transaction_id}
                  paymentId={p.payment_id}
                  leftMinor={p.left_minor}
                  label={`Retour du paiement de ${money(p.amount_minor, cur)} du ${frenchDate(p.booking_date)}${p.file_reference ? ` · ${p.file_reference}` : ""}${full ? "" : " (partiel)"}`}
                  effect={returnEffect({
                    amount: money(row.amount_minor, cur),
                    left: money((BigInt(p.left_minor) - BigInt(row.amount_minor)).toString(), cur),
                    full,
                    dateFr: frenchDate(row.booking_date),
                  })}
                  idempotencyKey={randomUUID()}
                />
              );
            })
        : null}
      {refunds.map((q) => (
        <LinkRefund
          key={q.refund_request_id}
          lineId={row.bank_transaction_id}
          refundId={q.refund_request_id}
          kind={row.direction === "debit" ? "refund" : "refund_returned"}
          label={`${row.direction === "debit" ? "Remboursement" : "Remboursement revenu"} ${q.end_to_end_id} · ${money(q.amount_minor, cur)}`}
          effect={
            row.direction === "debit"
              ? `Le débit est le virement ${q.end_to_end_id} à ${q.payee_name} : le remboursement sera comptabilisé à la date du débit.`
              : `Le virement ${q.end_to_end_id} est revenu impayé : le remboursement sera annulé à la date du crédit, et le montant redeviendra disponible sur le paiement.`
          }
          idempotencyKey={randomUUID()}
        />
      ))}
      <Explain lineId={row.bank_transaction_id} idempotencyKey={randomUUID()} />
    </div>
  );
}
