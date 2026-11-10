import Link from "next/link";
import { notFound } from "next/navigation";
import { Badge, InfoNote, Section, Stats, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { money } from "@/lib/payments/statements";
import { type InvoiceDetail, percent, refusalText } from "@/lib/remittance/credit-notes";
import { frenchDate } from "@/lib/remittance/runs";
import { CreditNotePanel } from "./credit-note-panel";

const REASON_LABEL: Record<string, string> = {
  commission: "commission du reversement",
  run_cancelled: "annulation d'un reversement",
  manual: "avoir manuel",
  reversal: "encaissements annulés",
};

/**
 * M2c-5b a commission invoice (design §14.1, §17.2; risk R2): what it charged, what credit notes took back, what it still
 * charges (HT) and owes (TTC), the files it charges, the credit notes that rectify it — a manual one with its reason
 * category and, for staff, its reason — and « Émettre un avoir » for an admin at aal2 when the invoice can take one (not
 * a credit note, something left to credit, no run in flight setting it off). Money staff; the database decides.
 */
export default async function CommissionInvoicePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { supabase } = await staffSession();
  const { data, error } = await supabase.rpc("commission_invoice_detail", { p_invoice_id: id });
  if (error || !data) notFound();
  const d = data as unknown as InvoiceDetail;
  const invoice = d.kind === "invoice";
  const refusal = refusalText(d.refusal);
  const title = `${invoice ? "Facture" : "Avoir"} ${d.number}`;
  return (
    <WidePage
      title={title}
      back={
        d.run_id
          ? { href: `/backoffice/reversements/${d.run_id}`, label: `Reversement ${d.run_number ?? ""}`.trim() }
          : { href: "/backoffice/reversements", label: "Reversements" }
      }
    >
      <div className="flex flex-wrap gap-2">
        <Badge tone="neutral">{REASON_LABEL[d.reason] ?? d.reason}</Badge>
        <Badge tone={d.settlement === "due" ? "action" : "neutral"}>
          {d.settlement === "due" ? "à régler au compte propre" : "à régler par compensation"}
        </Badge>
      </div>
      <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="invoice-head">
        {d.client_name ?? ""} · émise le {frenchDate(d.issue_date)}
        {d.mandate_reference ? ` · mandat ${d.mandate_reference}` : ""}
        {d.service_from && d.service_to ? ` · encaissements du ${frenchDate(d.service_from)} au ${frenchDate(d.service_to)}` : ""}
        {d.vat_rate ? ` · TVA ${percent(d.vat_rate)}` : ""}
      </p>
      <Stats
        items={[
          { label: "HT", value: money(d.ht, "EUR") },
          { label: "TTC", value: money(d.ttc, "EUR") },
          ...(invoice
            ? [
                { label: "Reste facturé (HT)", value: money(d.remaining_ht, "EUR"), testId: "invoice-remaining" },
                { label: "Reste dû (TTC)", value: money(d.open_ttc, "EUR"), testId: "invoice-open" },
              ]
            : []),
        ]}
      />

      {invoice ? (
        <Section title="Émettre un avoir" testId="credit-note">
          {refusal ? (
            <InfoNote>{refusal}</InfoNote>
          ) : d.can_credit ? (
            <CreditNotePanel
              invoiceId={d.id}
              invoiceNumber={d.number}
              remainingHt={d.remaining_ht}
              files={d.files.filter((f) => BigInt(f.open_ht) > BigInt(0))}
              currency="EUR"
            />
          ) : (
            <InfoNote>Seul un administrateur du cabinet, en double authentification, émet un avoir.</InfoNote>
          )}
        </Section>
      ) : null}

      <Section title="Avoirs qui rectifient cette facture" testId="invoice-credit-notes">
        {d.credit_notes.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun avoir.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
            {d.credit_notes.map((c) => (
              <li key={c.id} className="flex flex-col gap-1 py-3" data-testid="invoice-credit-note">
                <span className="flex flex-wrap items-center justify-between gap-2">
                  <Link href={`/backoffice/reversements/factures/${c.id}`} className="font-medium underline underline-offset-4">
                    Avoir {c.number} du {frenchDate(c.issue_date)}
                  </Link>
                  <span className="tabular-nums">
                    HT {money(c.ht, "EUR")} · TVA {money(c.vat, "EUR")}
                  </span>
                </span>
                <span className="text-sm text-zinc-600 dark:text-zinc-400">
                  {c.reason === "manual"
                    ? `Avoir manuel : ${c.reason_fr ?? ""}${c.reason_text ? ` — « ${c.reason_text} » (interne)` : ""}`
                    : `${REASON_LABEL[c.reason] ?? c.reason}${c.run_number ? ` · relevé ${c.run_number}` : ""}`}
                </span>
              </li>
            ))}
          </ul>
        )}
      </Section>

      {invoice ? (
        <Section title={`Dossiers facturés (${d.file_count})`} testId="invoice-files">
          <ul className="flex flex-col divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
            {d.files.map((f) => (
              <li key={f.account_id} className="flex flex-wrap justify-between gap-2 py-2">
                <span>Dossier {f.reference ?? f.account_id.slice(0, 8)}</span>
                <span className="tabular-nums">
                  reste facturé {money(f.open_ht, "EUR")}
                  {f.waived_ht !== "0" ? ` · rectifié par avoir manuel ${money(f.waived_ht, "EUR")}` : ""}
                </span>
              </li>
            ))}
          </ul>
          {d.file_count > d.files.length ? (
            <p className="mt-2 text-xs text-zinc-500">Les {d.files.length} premiers dossiers, par reste facturé.</p>
          ) : null}
        </Section>
      ) : null}
    </WidePage>
  );
}
