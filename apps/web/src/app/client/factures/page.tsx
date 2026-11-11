import Link from "next/link";
import { redirect } from "next/navigation";
import { Badge, InfoNote, Section, WidePage } from "@/components/ui";
import type { SessionClaims } from "@/lib/auth/access";
import { money } from "@/lib/payments/statements";
import { clientOfUser } from "@/lib/remittance/client-space";
import {
  NOT_ONLINE_TEXT,
  type PaymentReference,
  frenchDay,
  invoiceDelivery,
  invoiceKind,
  listPage,
  pageOf,
  settlementText,
} from "@/lib/remittance/documents";
import { creditNoteText } from "@/lib/remittance/credit-notes";
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
 *
 * M2c-5b: a credit note says which invoice it rectifies (« rectifie la facture FC-… du … », CGI 289 I 5) and, a manual
 * one, its reason category as its line states it — never the reason staff typed.
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
      "id, kind, reason, number, issue_date, settlement, due_date, run_id, totals:payload->totals, mandate:payload->mandate->>reference, acceptance:payload->buyer->>invoice_acceptance_ref, payment_reference:payload->payment_reference, designation:payload->lines->0->>designation_fr",
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
  // M2c-5b: each credit note names the invoices it rectifies (289 I 5), read from its corrections (the client's rows)
  const creditIds = invoices.rows.filter((i) => i.kind === "credit_note").map((i) => i.id);
  const { data: corrections } =
    creditIds.length > 0
      ? await supabase
          .from("commission_credit_correction")
          .select("credit_note_id, original_invoice_id")
          .in("credit_note_id", creditIds)
      : { data: [] as { credit_note_id: string; original_invoice_id: string }[] };
  const originalIds = [...new Set((corrections ?? []).map((c) => c.original_invoice_id))];
  const { data: originals } =
    originalIds.length > 0
      ? await supabase.from("commission_invoice").select("id, number, issue_date").in("id", originalIds)
      : { data: [] as { id: string; number: string; issue_date: string }[] };
  const originalOf = new Map((originals ?? []).map((o) => [o.id, o]));
  const correctedOf = new Map<string, { number: string; issue_date: string }[]>();
  for (const c of corrections ?? []) {
    const o = originalOf.get(c.original_invoice_id);
    if (o) correctedOf.set(c.credit_note_id, [...(correctedOf.get(c.credit_note_id) ?? []), o]);
  }
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
                  {inv.kind === "credit_note" && correctedOf.has(inv.id) ? (
                    <span className="text-sm" data-testid="invoice-rectifies">
                      {creditNoteText(
                        { kind: inv.kind, reason: inv.reason, designation: (inv.designation as string | null) ?? null },
                        [...(correctedOf.get(inv.id) ?? [])].sort((a, b) => a.number.localeCompare(b.number)),
                      )}
                    </span>
                  ) : null}
                  <span className="text-sm text-zinc-600 dark:text-zinc-400">
                    {t ? `HT ${money(t.ht_minor, "EUR")} · TVA ${money(t.vat_minor, "EUR")} · ` : ""}
                    {inv.mandate ? `mandat ${String(inv.mandate)} · ` : ""}
                    {settlementText({ ...inv, payment_reference: (inv.payment_reference ?? null) as PaymentReference | null })}
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
