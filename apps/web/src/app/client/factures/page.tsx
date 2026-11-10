import Link from "next/link";
import { redirect } from "next/navigation";
import { Badge, InfoNote, Section, WidePage } from "@/components/ui";
import type { SessionClaims } from "@/lib/auth/access";
import { money } from "@/lib/payments/statements";
import { clientOfUser } from "@/lib/remittance/client-space";
import {
  NOT_ONLINE_TEXT,
  frenchDay,
  invoiceDelivery,
  invoiceKind,
  listPage,
  pageOf,
  settlementText,
} from "@/lib/remittance/documents";
import { createClient } from "@/lib/supabase/server";

type Totals = { ht_minor: string; vat_minor: string; ttc_minor: string };

const PAGE_SIZE = 200;

/**
 * M2c-5 « Factures » (client space, design §14.2, §17.7): the commission invoices and credit notes of the client, newest
 * first, a page at a time, with their amounts as frozen at issue. The PDF is served here once the client accepted
 * electronic invoices (CGI 289 VI: recorded at issue); otherwise the page says the PDF is not available online and to
 * ask the servicer for it — never that it was posted, since no dispatch is recorded yet (review M2c-5 legal#7, K6;
 * OQ-74). Whole-client members only (OQ-48); RLS decides.
 *
 * Review M2c-5 (perf#3, tests-ui#7): the PDFs are read for the invoices shown only (`.in()`, at most 200 ids), not every
 * PDF of the client (cut at 1,000 by PostgREST, the newest first to go); the list pages (« Plus anciennes »).
 */
export default async function ClientInvoicesPage({ searchParams }: PageProps<"/client/factures">) {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  const claims = (data?.claims ?? null) as SessionClaims | null;
  if (!claims?.sub) redirect("/connexion");
  const back = { href: "/client/reversements", label: "Reversements" };
  const { client, restricted } = await clientOfUser(supabase, claims);
  if (!client || restricted) {
    return (
      <WidePage title="Factures et avoirs" back={back}>
        <InfoNote>
          {client
            ? "Vos accès ne couvrent pas les factures de commission : elles portent sur tous les portefeuilles du client."
            : "Aucun client rattaché à votre compte."}
        </InfoNote>
      </WidePage>
    );
  }
  const list = listPage((await searchParams).page, PAGE_SIZE);
  const { data: invoiceRows } = await supabase
    .from("commission_invoice")
    .select(
      "id, kind, number, issue_date, settlement, due_date, run_id, totals:payload->totals, mandate:payload->mandate->>reference, acceptance:payload->buyer->>invoice_acceptance_ref",
    )
    .eq("client_organization_id", client.id)
    .order("issue_date", { ascending: false })
    .order("seq", { ascending: false })
    .range(list.from, list.to);
  const invoices = pageOf(invoiceRows, PAGE_SIZE);
  const ids = invoices.rows.map((i) => i.id);
  const { data: pdfs } =
    ids.length > 0
      ? await supabase.from("commission_invoice_document").select("invoice_id, document_id").in("invoice_id", ids)
      : { data: [] as { invoice_id: string; document_id: string }[] };
  const pdfOf = new Map((pdfs ?? []).map((p) => [p.invoice_id, p]));
  const href = (page: number) => (page > 0 ? `/client/factures?page=${page}` : "/client/factures");
  return (
    <WidePage title="Factures et avoirs" back={back}>
      <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="invoices-client">
        {client.name} · les factures de notre commission de recouvrement et leurs avoirs, numérotés dans une seule série.
      </p>
      <Section title="Documents" testId="invoices">
        {invoices.rows.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">
            {list.page > 0 ? "Aucune facture plus ancienne." : "Aucune facture pour l'instant."}
          </p>
        ) : (
          <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
            {invoices.rows.map((inv) => {
              const t = (inv.totals ?? null) as unknown as Totals | null;
              const delivery = invoiceDelivery(
                { payload: { buyer: { invoice_acceptance_ref: inv.acceptance as string | null } } },
                pdfOf.get(inv.id) ?? null,
              );
              return (
                <li key={inv.id} className="flex flex-col gap-1 py-3" data-testid="invoice-row">
                  <span className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-medium">
                      {invoiceKind(inv.kind)} {inv.number} du {frenchDay(inv.issue_date)}
                    </span>
                    <span className="tabular-nums">{t ? `${money(t.ttc_minor, "EUR")} TTC` : "—"}</span>
                  </span>
                  <span className="text-sm text-zinc-600 dark:text-zinc-400">
                    {t ? `HT ${money(t.ht_minor, "EUR")} · TVA ${money(t.vat_minor, "EUR")} · ` : ""}
                    {inv.mandate ? `mandat ${String(inv.mandate)} · ` : ""}
                    {settlementText(inv)}
                  </span>
                  {delivery.mode === "pdf" ? (
                    <a
                      href={`/client/reversements/documents/${delivery.documentId}`}
                      className="text-sm font-medium underline underline-offset-4"
                      data-testid="invoice-pdf"
                    >
                      {invoiceKind(inv.kind)} (PDF)
                    </a>
                  ) : delivery.mode === "not_online" ? (
                    <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="invoice-not-online">
                      {NOT_ONLINE_TEXT}
                    </p>
                  ) : (
                    <Badge tone="busy">PDF en préparation</Badge>
                  )}
                </li>
              );
            })}
          </ul>
        )}
        {list.page > 0 || invoices.more ? (
          <nav className="mt-3 flex justify-between gap-3 text-sm" aria-label="Pages des factures">
            {list.page > 0 ? (
              <Link href={href(list.page - 1)} className="underline underline-offset-4">
                ← Plus récentes
              </Link>
            ) : (
              <span />
            )}
            {invoices.more ? (
              <Link href={href(list.page + 1)} className="underline underline-offset-4" data-testid="invoices-older">
                Plus anciennes →
              </Link>
            ) : null}
          </nav>
        ) : null}
      </Section>
      <Link href="/client/reversements" className="text-sm underline underline-offset-4">
        Relevés de reversement
      </Link>
    </WidePage>
  );
}
