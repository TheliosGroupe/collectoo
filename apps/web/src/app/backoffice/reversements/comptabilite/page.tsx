import { InfoNote, Section, WidePage, inlineButtonClass, inputClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { exportPeriod } from "@/lib/remittance/documents";

function isoDay(d: Date): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(d);
}

/**
 * M2c-5 (design §14.2, §17): the accountant's export — the invoices and credit notes of a period with their
 * settlements, and the entries of the servicer's books. Two CSV files in French conventions. Not a FEC (the servicer's
 * general ledger is out of scope). Money staff at aal2; the database decides.
 */
export default async function AccountingExportPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await staffSession();
  const q = await searchParams;
  const today = isoDay(new Date());
  const from = typeof q.du === "string" ? q.du : `${today.slice(0, 7)}-01`;
  const to = typeof q.au === "string" ? q.au : today;
  const period = exportPeriod(from, to);
  const link = (type: string) => `/backoffice/reversements/comptabilite/export?${new URLSearchParams({ type, du: from, au: to })}`;
  return (
    <WidePage title="Export comptable" back={{ href: "/backoffice/reversements", label: "Reversements" }}>
      <p className="text-sm text-zinc-600 dark:text-zinc-400">
        Pour votre expert-comptable : les factures et avoirs de commission émis sur la période avec leurs règlements, et les
        écritures des comptes du cabinet (7060, 44571, 44574, 4111, 4112, 5122, 6270, 6780). Fichiers CSV (séparateur « ; »,
        montants en euros et en centimes). Ce n&apos;est pas un fichier des écritures comptables (FEC) : la comptabilité
        générale du cabinet reste tenue à part.
      </p>
      <Section title="Période">
        <form className="flex flex-col gap-3 sm:flex-row sm:items-end" data-testid="export-period">
          <label className="flex flex-col gap-1 text-sm">
            Du
            <input type="date" name="du" defaultValue={from} className={inputClass} required />
          </label>
          <label className="flex flex-col gap-1 text-sm">
            Au
            <input type="date" name="au" defaultValue={to} className={inputClass} required />
          </label>
          <button type="submit" className={inlineButtonClass}>
            Choisir
          </button>
        </form>
      </Section>
      {period ? (
        <Section title="Fichiers">
          <ul className="flex flex-col gap-2 text-sm">
            <li>
              <a href={link("factures")} className="font-medium underline underline-offset-4" data-testid="export-documents">
                Factures et avoirs (CSV)
              </a>
            </li>
            <li>
              <a href={link("ecritures")} className="font-medium underline underline-offset-4" data-testid="export-entries">
                Écritures des comptes du cabinet (CSV)
              </a>
            </li>
          </ul>
        </Section>
      ) : (
        <InfoNote>Choisissez une période d&apos;un an au plus.</InfoNote>
      )}
    </WidePage>
  );
}
