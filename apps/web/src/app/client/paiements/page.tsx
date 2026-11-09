import Link from "next/link";
import { redirect } from "next/navigation";
import { Badge, InfoNote, WidePage } from "@/components/ui";
import { componentLabel } from "@/lib/payments/allocation";
import { frenchDate } from "@/lib/payments/bank-accounts";
import { type FeedRow, feedKind, feedReason, feedReceiptLabel } from "@/lib/payments/receipts";
import { money } from "@/lib/payments/statements";
import { createClient } from "@/lib/supabase/server";

const PAGE_SIZE = 20;

function frenchDateTime(iso: string): string {
  return new Intl.DateTimeFormat("fr-FR", { dateStyle: "short", timeStyle: "short", timeZone: "Europe/Paris" }).format(
    new Date(iso),
  );
}

/**
 * M2b-5 « Paiements reçus » (client space, R124-5, founder #17): every payment allocated, reversed, forwarded or
 * held on the client's files, newest first, the amounts from the ledger, the items each allocation paid and the
 * receipt the debtor gets (R124-6). Reading the page records the delivery of the rows shown (they are marked
 * « Nouveau » once). Phone-first; RLS and the feed function keep each client to its own portfolios.
 */
export default async function ClientPaymentsPage({ searchParams }: PageProps<"/client/paiements">) {
  const query = await searchParams;
  const after = typeof query.apres === "string" ? query.apres : null;
  const supabase = await createClient();
  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims?.sub) redirect("/connexion");

  const { data: orgs } = await supabase
    .from("organization")
    .select("id, legal_name, kind")
    .neq("kind", "servicer")
    .order("legal_name");
  const clients = orgs ?? [];
  const wanted = typeof query.client === "string" ? query.client : null;
  const client = clients.find((o) => o.id === wanted) ?? clients[0];
  const back = { href: "/client", label: "Espace client" };
  if (!client) {
    return (
      <WidePage title="Paiements reçus" back={back}>
        <InfoNote>Aucun client n&apos;est rattaché à votre compte.</InfoNote>
      </WidePage>
    );
  }
  const { data, error } = await supabase.rpc("client_payment_feed", {
    p_client: client.id,
    p_after: after ?? undefined,
    p_limit: PAGE_SIZE,
  });
  const rows = (data ?? []) as unknown as FeedRow[];
  const next = rows.length === PAGE_SIZE ? rows[rows.length - 1].cursor : null;
  const link = (params: Record<string, string>) =>
    `/client/paiements?${new URLSearchParams({ ...(clients.length > 1 ? { client: client.id } : {}), ...params })}`;

  return (
    <WidePage title="Paiements reçus" back={back}>
      <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="feed-client">
        {client.legal_name} · paiements de vos débiteurs, imputés ou mis en attente par nos services. Chaque paiement
        rattaché à un dossier a sa quittance (PDF), établie à partir de la comptabilité.
      </p>
      {clients.length > 1 ? (
        <nav className="flex flex-wrap gap-2 text-sm">
          {clients.map((o) => (
            <Link
              key={o.id}
              href={`/client/paiements?client=${o.id}`}
              className={o.id === client.id ? "font-medium underline underline-offset-4" : "underline-offset-4 hover:underline"}
            >
              {o.legal_name}
            </Link>
          ))}
        </nav>
      ) : null}
      {error ? <InfoNote>Les paiements ne peuvent pas être affichés pour l&apos;instant. Réessayez.</InfoNote> : null}
      {!error && rows.length === 0 ? (
        <InfoNote>{after ? "Aucun paiement plus ancien." : "Aucun paiement reçu pour vos dossiers pour l'instant."}</InfoNote>
      ) : null}
      <ul className="flex flex-col gap-3" data-testid="feed">
        {rows.map((r) => {
          const kind = feedKind(r.kind);
          const why = feedReason(r.reason);
          const receipt = feedReceiptLabel(r);
          return (
            <li
              key={r.notification_id}
              className="rounded-lg border border-zinc-200 p-4 dark:border-zinc-800"
              data-testid="feed-row"
              data-kind={r.kind}
            >
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="flex flex-wrap items-center gap-2">
                  <Badge tone={kind.tone}>{kind.label}</Badge>
                  {r.first_view ? (
                    <Badge tone="busy" testId="feed-new">
                      Nouveau
                    </Badge>
                  ) : null}
                </span>
                <span className="text-xs text-zinc-600 dark:text-zinc-400">{frenchDateTime(r.created_at)}</span>
              </div>
              <p className="mt-2 text-lg font-semibold tabular-nums" data-testid="feed-amount">
                {money(r.amount_minor, r.currency)}{" "}
                <span className="text-sm font-normal text-zinc-600 dark:text-zinc-400">{kind.amount}</span>
              </p>
              <p className="text-sm">
                Dossier {r.file_reference ?? "–"}
                {r.debtor_name ? ` · ${r.debtor_name}` : ""} · reçu le {frenchDate(r.booking_date)}
              </p>
              {why ? <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">{why}</p> : null}
              {r.lines.length > 0 ? (
                <ul className="mt-2 flex flex-col gap-0.5 text-sm" data-testid="feed-lines">
                  {r.lines.map((l, i) => (
                    <li key={i} className="flex justify-between gap-3">
                      <span className="break-words">
                        {l.item_ref} · {componentLabel(l.component)}
                        {l.due_date ? (
                          <span className="text-xs text-zinc-600 dark:text-zinc-400"> · échéance {frenchDate(l.due_date)}</span>
                        ) : null}
                      </span>
                      <span className="tabular-nums">{money(l.amount_minor, r.currency)}</span>
                    </li>
                  ))}
                </ul>
              ) : null}
              {receipt && r.receipt_id ? (
                <p className="mt-2 text-sm">
                  <a href={`/client/quittances/${r.receipt_id}`} className="underline underline-offset-4" data-testid="feed-receipt">
                    {receipt} (PDF)
                  </a>
                </p>
              ) : !["payment_allocation_reversed", "payment_forward_reversed", "payment_returned"].includes(r.kind) ? (
                <p className="mt-2 text-xs text-zinc-600 dark:text-zinc-400">Quittance en cours d&apos;établissement.</p>
              ) : null}
            </li>
          );
        })}
      </ul>
      <div className="flex flex-wrap gap-4 text-sm">
        {after ? (
          <Link href={link({})} className="underline underline-offset-4">
            ← Les plus récents
          </Link>
        ) : null}
        {next ? (
          <Link href={link({ apres: next })} className="underline underline-offset-4" data-testid="feed-older">
            Paiements plus anciens →
          </Link>
        ) : null}
      </div>
    </WidePage>
  );
}
