import Link from "next/link";
import { notFound } from "next/navigation";
import { Badge, InfoNote, Section, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { frenchDate } from "@/lib/payments/bank-accounts";
import { LINE_FILTERS, lineState, maskedIban, money, signedMoney } from "@/lib/payments/statements";
import { AutoRefresh } from "@/components/auto-refresh";
import { type StatementRow, STATEMENT_COLUMNS, StatementSummary } from "../../statement-summary";

const PAGE_SIZE = 100;

type LineRow = {
  id: string;
  line_no: number;
  direction: string;
  amount: string;
  booking_date: string;
  value_date: string | null;
  kind: string;
  counterparty_name: string | null;
  counterparty_iban: string | null;
  remittance_text: string | null;
  creditor_reference: string | null;
  return_reason: string | null;
  payment: { id: string }[];
};

/** M2b-2: one statement and its lines, with what became of each (booked, to classify, held). */
export default async function StatementPage({
  params,
  searchParams,
}: PageProps<"/backoffice/encaissements/releves/[id]">) {
  const { id } = await params;
  const query = await searchParams;
  const filter = typeof query.type === "string" && query.type in LINE_FILTERS ? query.type : "toutes";
  const page = Math.max(1, Number.parseInt(typeof query.page === "string" ? query.page : "1", 10) || 1);
  const { supabase } = await staffSession();

  const { data: statement } = await supabase.from("bank_statement").select(STATEMENT_COLUMNS).eq("id", id).maybeSingle();
  if (!statement) notFound();
  const s = statement as unknown as StatementRow;

  let lines = supabase
    .from("bank_transaction")
    .select(
      // amount as text: integer minor units never pass through a JS number
      "id, line_no, direction, amount:amount_minor::text, booking_date, value_date, kind, counterparty_name," +
        " counterparty_iban, remittance_text, creditor_reference, return_reason, payment(id)",
      { count: "exact" },
    )
    .eq("statement_id", id);
  const kinds = LINE_FILTERS[filter].kinds;
  if (kinds) lines = lines.in("kind", kinds);
  const { data, count } = await lines.order("line_no").range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  const rows = (data ?? []) as unknown as LineRow[];
  const total = count ?? 0;
  const href = (p: number, t: string = filter) =>
    `/backoffice/encaissements/releves/${id}?type=${t}${p > 1 ? `&page=${p}` : ""}`;

  return (
    <WidePage title={s.file_name} back={{ href: "/backoffice/encaissements", label: "Relevés bancaires" }}>
      <AutoRefresh active={s.status === "uploaded"} abandonable={false} />
      {query.deja === "1" ? <InfoNote>Ce fichier a déjà été déposé pour ce compte : voici le relevé existant.</InfoNote> : null}
      <StatementSummary s={s} />

      {s.counts && s.counts.cash_in.length > 0 ? (
        <Section title="Comptabilisé par jour (fonds de tiers à affecter)" testId="cash-in">
          <ul className="grid gap-1 text-sm sm:grid-cols-2">
            {s.counts.cash_in.map((c) => (
              <li key={c.date} className="flex justify-between gap-3 rounded-md bg-zinc-50 px-3 py-2 dark:bg-zinc-900">
                <span>{frenchDate(c.date)}</span>
                <span className="font-medium tabular-nums">{money(c.minor, s.currency)}</span>
              </li>
            ))}
          </ul>
        </Section>
      ) : null}

      {s.status === "imported" ? (
        <Section title="Opérations" testId="statement-lines">
          <nav className="mb-3 flex flex-wrap gap-2 text-sm" aria-label="Filtrer les opérations">
            {Object.entries(LINE_FILTERS).map(([key, f]) => (
              <Link
                key={key}
                href={href(1, key)}
                aria-current={key === filter ? "page" : undefined}
                className={`rounded-full border px-3 py-1 ${
                  key === filter
                    ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                    : "border-zinc-300 dark:border-zinc-700"
                }`}
              >
                {f.label}
              </Link>
            ))}
          </nav>
          {rows.length === 0 ? (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">
              {s.counts && s.counts.new_lines === 0
                ? "Toutes les opérations de ce fichier avaient déjà été importées : rien de nouveau."
                : "Aucune opération dans cette catégorie."}
            </p>
          ) : (
            <ul className="divide-y divide-zinc-200 dark:divide-zinc-800" data-testid="line-list">
              {rows.map((l) => {
                const state = lineState({ kind: l.kind, direction: l.direction, has_payment: l.payment.length > 0 });
                return (
                  <li key={l.id} className="grid gap-1 py-3 sm:grid-cols-[7rem_1fr_auto] sm:gap-4">
                    <span className="text-sm text-zinc-600 dark:text-zinc-400">{frenchDate(l.booking_date)}</span>
                    <div className="min-w-0">
                      <p className="font-medium break-words">
                        {l.counterparty_name ?? "Contrepartie non indiquée"}
                        {l.counterparty_iban ? (
                          <span className="ml-2 text-xs font-normal text-zinc-600 dark:text-zinc-400">
                            {maskedIban(l.counterparty_iban)}
                          </span>
                        ) : null}
                      </p>
                      {l.remittance_text ? (
                        <p className="line-clamp-2 text-sm break-words text-zinc-600 dark:text-zinc-400">{l.remittance_text}</p>
                      ) : null}
                      {l.creditor_reference ? (
                        <p className="font-mono text-xs text-zinc-600 dark:text-zinc-400">Réf. {l.creditor_reference}</p>
                      ) : null}
                      <p className="mt-1 flex flex-wrap gap-2">
                        <Badge tone="neutral">{state.kind}</Badge>
                        <Badge tone={state.tone}>{state.state}</Badge>
                        {l.return_reason ? <Badge tone="neutral">Motif {l.return_reason}</Badge> : null}
                      </p>
                    </div>
                    <span
                      className={`text-right font-medium tabular-nums ${
                        l.direction === "debit" ? "text-red-800 dark:text-red-300" : ""
                      }`}
                    >
                      {signedMoney(l.direction, l.amount, s.currency)}
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
          {total > PAGE_SIZE ? (
            <nav className="mt-3 flex items-center justify-between gap-3 text-sm" aria-label="Pages">
              {page > 1 ? <Link href={href(page - 1)}>← Précédentes</Link> : <span />}
              <span className="text-zinc-600 dark:text-zinc-400">
                {(page - 1) * PAGE_SIZE + 1}–{Math.min(page * PAGE_SIZE, total)} sur {total}
              </span>
              {page * PAGE_SIZE < total ? <Link href={href(page + 1)}>Suivantes →</Link> : <span />}
            </nav>
          ) : null}
        </Section>
      ) : null}
    </WidePage>
  );
}
