import { inputClass } from "@/components/ui";
import { type Address, type BillingIdentity, LEGAL_FORMS, capitalFieldValue } from "@/lib/remittance/terms";

function AddressFields({ prefix, legend, value, required }: { prefix: string; legend: string; value: Address | null; required: boolean }) {
  return (
    <fieldset className="flex flex-col gap-2 rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
      <legend className="px-1 text-sm font-medium">{legend}</legend>
      <label className="flex flex-col gap-1 text-sm">
        Adresse
        <input name={`${prefix}_line1`} required={required} maxLength={140} defaultValue={value?.line1 ?? ""} className={inputClass} />
      </label>
      <label className="flex flex-col gap-1 text-sm">
        Complément (facultatif)
        <input name={`${prefix}_line2`} maxLength={140} defaultValue={value?.line2 ?? ""} className={inputClass} />
      </label>
      <div className="grid grid-cols-[7rem_1fr_5rem] gap-2">
        <label className="flex flex-col gap-1 text-sm">
          Code postal
          <input
            name={`${prefix}_postcode`}
            required={required}
            maxLength={16}
            inputMode="numeric"
            defaultValue={value?.postcode ?? ""}
            className={inputClass}
          />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Ville
          <input name={`${prefix}_city`} required={required} maxLength={80} defaultValue={value?.city ?? ""} className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Pays
          <input
            name={`${prefix}_country`}
            maxLength={2}
            defaultValue={value?.country ?? "FR"}
            autoCapitalize="characters"
            className={inputClass}
          />
        </label>
      </div>
    </fieldset>
  );
}

/**
 * M2c-2: the fields of a billing identity (design §6.1; what invoices, statements and receipts print: C. com. R123-237,
 * R123-238, CGI ann. II 242 nonies A 1°–2°). The servicer prints every mention, so its form asks for all of them; a
 * client's asks what invoicing it needs (SIREN, registered office, billing address, professional, PDF acceptance).
 * Review M2c-2: « professionnel » is an explicit choice for a new client (never pre-ticked: it is what the founder #13
 * gate tests); « en liquidation » is the servicer's mention only (R123-237 4° on its own documents) — a client's
 * liquidation is an event, recorded with its evidence in « Événements du client ».
 */
export function IdentityFields({
  kind,
  legalName,
  siren,
  identity,
}: {
  kind: "servicer" | "client";
  legalName: string;
  siren: string | null;
  identity: BillingIdentity | null;
}) {
  // integer minor units read as text (BILLING_IDENTITY_COLUMNS), shown in euros without a float
  const capital = capitalFieldValue(identity?.share_capital_minor);
  return (
    <>
      <input type="hidden" name="expected_version" value={identity?.version ?? ""} readOnly />
      <label className="flex flex-col gap-1 text-sm">
        Raison sociale (ou nom et prénom)
        <input name="legal_name" required maxLength={200} defaultValue={legalName} className={inputClass} />
      </label>
      <div className="grid gap-4 sm:grid-cols-2">
        <label className="flex flex-col gap-1 text-sm">
          SIREN
          <input
            name="siren"
            required={kind === "servicer"}
            inputMode="numeric"
            maxLength={11}
            placeholder="849 678 297"
            defaultValue={siren ?? ""}
            className={`${inputClass} font-mono`}
          />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Forme juridique
          <select name="legal_form" defaultValue={identity?.legal_form ?? ""} className={inputClass}>
            <option value="">—</option>
            {LEGAL_FORMS.filter((f) => kind === "client" || f.value !== "OTHER").map((f) => (
              <option key={f.value} value={f.value}>
                {f.label}
              </option>
            ))}
          </select>
        </label>
        {kind === "servicer" ? (
          <>
            <label className="flex flex-col gap-1 text-sm">
              Capital social (€)
              <input name="share_capital" inputMode="decimal" placeholder="10 000" defaultValue={capital} className={inputClass} />
            </label>
            <label className="flex flex-col gap-1 text-sm">
              Ville du greffe (RCS)
              <input name="rcs_city" required maxLength={80} defaultValue={identity?.rcs_city ?? ""} className={inputClass} />
            </label>
          </>
        ) : null}
        <label className="flex flex-col gap-1 text-sm">
          N° de TVA intracommunautaire{kind === "client" ? " (facultatif)" : ""}
          <input
            name="vat_number"
            required={kind === "servicer"}
            maxLength={20}
            placeholder="FR33849678297"
            defaultValue={identity?.vat_number ?? ""}
            className={`${inputClass} font-mono`}
          />
        </label>
      </div>
      <AddressFields prefix="office" legend="Siège social" value={identity?.registered_office ?? null} required />
      {kind === "client" ? (
        <>
          <AddressFields
            prefix="billing"
            legend="Adresse de facturation, si elle diffère du siège"
            value={identity?.billing_address ?? null}
            required={false}
          />
          <fieldset className="flex flex-col gap-2 rounded-md border border-zinc-200 p-3 dark:border-zinc-800" data-testid="professional">
            <legend className="px-1 text-sm font-medium">
              Client professionnel ? (seuls les professionnels établis en France métropolitaine sont servis)
            </legend>
            <div className="flex flex-wrap gap-4 text-sm">
              <label className="flex items-center gap-2">
                <input
                  type="radio"
                  name="is_professional"
                  value="on"
                  required
                  defaultChecked={identity ? identity.is_professional : undefined}
                />
                Oui, un professionnel
              </label>
              <label className="flex items-center gap-2">
                <input
                  type="radio"
                  name="is_professional"
                  value="off"
                  required
                  defaultChecked={identity ? !identity.is_professional : undefined}
                />
                Non
              </label>
            </div>
          </fieldset>
          <label className="flex flex-col gap-1 text-sm">
            Acceptation des factures PDF (clause ou accord écrit ; vide : envoi postal)
            <input
              name="invoice_acceptance_ref"
              maxLength={200}
              placeholder="art. 11 du mandat"
              defaultValue={identity?.invoice_acceptance_ref ?? ""}
              className={inputClass}
            />
          </label>
          <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="client-liquidation-note">
            Une procédure collective, une liquidation judiciaire, un décès ou la fin du mandat s&apos;enregistrent avec leur
            justificatif dans{" "}
            <a href="#evenements" className="underline underline-offset-4">
              « Événements du client »
            </a>
            .
          </p>
        </>
      ) : (
        <>
          <input type="hidden" name="is_professional" value="on" readOnly />
          <label className="flex items-start gap-2 text-sm">
            <input type="checkbox" name="in_liquidation" defaultChecked={identity?.in_liquidation ?? false} className="mt-1" />
            <span>
              Le cabinet est en liquidation : ses quittances, relevés et factures portent la mention « en liquidation »
              (obligatoire, art. R123-237 4° C. com.)
            </span>
          </label>
        </>
      )}
    </>
  );
}
