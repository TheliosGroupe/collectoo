import Link from "next/link";
import { notFound } from "next/navigation";
import { Badge, InfoNote, Section, Stats, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { money } from "@/lib/payments/statements";
import {
  type FileChoice,
  type InvoiceDetail,
  creditNoteBack,
  invoiceFilesPage,
  invoiceFilesRpc,
  percent,
  reasonCategoryLabel,
  refusalText,
} from "@/lib/remittance/credit-notes";
import { frenchDate } from "@/lib/remittance/runs";
import { CreditNotePanel } from "./credit-note-panel";

const REASON_LABEL: Record<string, string> = {
  commission: "commission du reversement",
  run_cancelled: "annulation d'un reversement",
  manual: "avoir manuel",
  reversal: "encaissements annulés",
};

type Corrected = { id: string; number: string; issue_date: string; ht: string; vat: string };

/**
 * M2c-5b a commission invoice (design §14.1, §17.2; risk R2): what it charged, what credit notes took back, what it still
 * charges (HT) and owes (TTC), the files it charges, the credit notes that rectify it — a manual one with its reason
 * category and, for staff, its reason — and « Émettre un avoir » for an admin at aal2 when the invoice can take one (not
 * a credit note, something left to credit, no run in flight setting it off or able to cancel it). Money staff; the
 * database decides.
 *
 * Review M2c-5b: « Sur » offers every file the invoice still charges, a page of 200 at a time
 * (`public.commission_invoice_files`, tests-ui#2); a credit note's own page names the invoices it rectifies, with what it
 * took off each, a manual one's category and reason, and goes back to the invoice when no run issued it (tests-ui#3).
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

  // the file choice: the first page of the paged read; if it fails, the 200 files the detail lists (said so)
  let files: FileChoice[] = [];
  let nextFiles: string | null = null;
  let filesPartial = false;
  if (invoice && !refusal && d.can_credit) {
    const page = await invoiceFilesPage(invoiceFilesRpc(supabase), d.id, null);
    if ("error" in page) {
      console.error("invoice files failed", { error: page.error });
      files = d.files.filter((f) => BigInt(f.open_ht) > BigInt(0)).map((f) => ({ account_id: f.account_id, reference: f.reference }));
      filesPartial = d.file_count > d.files.length;
    } else {
      files = page.files;
      nextFiles = page.next;
    }
  }

  // a credit note: the invoices it rectifies (its corrections, money staff's rows) and, a manual one, its reason
  let corrected: Corrected[] = [];
  let manual: { reason_code: string; reason: string } | null = null;
  if (!invoice) {
    const { data: corrections } = await supabase
      .from("commission_credit_correction")
      .select("original_invoice_id, ht:ht_minor::text, vat:vat_minor::text")
      .eq("credit_note_id", d.id);
    const ids = (corrections ?? []).map((c) => c.original_invoice_id);
    const { data: originals } =
      ids.length > 0
        ? await supabase.from("commission_invoice").select("id, number, issue_date").in("id", ids)
        : { data: [] as { id: string; number: string; issue_date: string }[] };
    const originalOf = new Map((originals ?? []).map((o) => [o.id, o]));
    corrected = (corrections ?? [])
      .flatMap((c) => {
        const o = originalOf.get(c.original_invoice_id);
        return o ? [{ id: o.id, number: o.number, issue_date: o.issue_date, ht: String(c.ht), vat: String(c.vat) }] : [];
      })
      .sort((a, b) => a.number.localeCompare(b.number));
    if (d.reason === "manual") {
      const { data: m } = await supabase
        .from("manual_credit_note")
        .select("reason_code, reason")
        .eq("credit_note_id", d.id)
        .maybeSingle();
      manual = m ?? null;
    }
  }

  return (
    <WidePage title={title} back={creditNoteBack(d, invoice ? [] : corrected)}>
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
              files={files}
              nextFiles={nextFiles}
              filesPartial={filesPartial}
              currency="EUR"
            />
          ) : (
            <InfoNote>Seul un administrateur du cabinet, en double authentification, émet un avoir.</InfoNote>
          )}
        </Section>
      ) : null}

      {invoice ? (
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
      ) : (
        <Section title={corrected.length > 1 ? "Factures rectifiées" : "Facture rectifiée"} testId="credit-note-corrects">
          {corrected.length === 0 ? (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">Facture rectifiée introuvable.</p>
          ) : (
            <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
              {corrected.map((c) => (
                <li key={c.id} className="flex flex-wrap items-center justify-between gap-2 py-3" data-testid="credit-note-corrected">
                  <span>
                    Rectifie la{" "}
                    <Link href={`/backoffice/reversements/factures/${c.id}`} className="font-medium underline underline-offset-4">
                      facture {c.number} du {frenchDate(c.issue_date)}
                    </Link>
                  </span>
                  <span className="tabular-nums">
                    HT {money(c.ht, "EUR")} · TVA {money(c.vat, "EUR")}
                  </span>
                </li>
              ))}
            </ul>
          )}
          {manual ? (
            <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400" data-testid="credit-note-reason">
              Avoir manuel : {reasonCategoryLabel(manual.reason_code)} — « {manual.reason} » (interne, jamais sur l&apos;avoir)
            </p>
          ) : null}
        </Section>
      )}

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
