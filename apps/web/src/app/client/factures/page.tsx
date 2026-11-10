import Link from "next/link";
import { redirect } from "next/navigation";
import { Badge, InfoNote, Section, WidePage } from "@/components/ui";
import type { SessionClaims } from "@/lib/auth/access";
import { money } from "@/lib/payments/statements";
import { clientOfUser } from "@/lib/remittance/client-space";
import { frenchDay, invoiceDelivery, invoiceKind, settlementText } from "@/lib/remittance/documents";
import { createClient } from "@/lib/supabase/server";

type Totals = { ht_minor: string; vat_minor: string; ttc_minor: string };

/**
 * M2c-5 « Factures » (client space, design §14.2, §17.7): the commission invoices and credit notes of the client, newest
 * first, with their amounts as frozen at issue. The PDF is served here once the client accepted electronic invoices
 * (CGI 289 VI: recorded at issue); otherwise the invoice is « adressée par courrier ». Whole-client members only
 * (OQ-48); RLS decides.
 */
export default async function ClientInvoicesPage() {
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
  const [{ data: invoices }, { data: pdfs }] = await Promise.all([
    supabase
      .from("commission_invoice")
      .select(
        "id, kind, number, issue_date, settlement, due_date, run_id, totals:payload->totals, mandate:payload->mandate->>reference, acceptance:payload->buyer->>invoice_acceptance_ref",
      )
      .eq("client_organization_id", client.id)
      .order("issue_date", { ascending: false })
      .order("seq", { ascending: false })
      .limit(200),
    supabase.from("commission_invoice_document").select("invoice_id, document_id").eq("client_organization_id", client.id),
  ]);
  const pdfOf = new Map((pdfs ?? []).map((p) => [p.invoice_id, p]));
  return (
    <WidePage title="Factures et avoirs" back={back}>
      <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="invoices-client">
        {client.name} · les factures de notre commission de recouvrement et leurs avoirs, numérotés dans une seule série.
      </p>
      <Section title="Documents" testId="invoices">
        {(invoices ?? []).length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucune facture pour l&apos;instant.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
            {(invoices ?? []).map((inv) => {
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
                  ) : delivery.mode === "post" ? (
                    <Badge tone="neutral" testId="invoice-post">
                      Adressée par courrier
                    </Badge>
                  ) : (
                    <Badge tone="busy">PDF en préparation</Badge>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </Section>
      <Link href="/client/reversements" className="text-sm underline underline-offset-4">
        Relevés de reversement
      </Link>
    </WidePage>
  );
}
