import { randomUUID } from "node:crypto";
import { ActionForm } from "@/components/action-form";
import { IdentityFields } from "@/components/identity-fields";
import { Badge, InfoNote, Section, WidePage, buttonClass, inputClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { BILLING_IDENTITY_COLUMNS, GAP_LABEL, type BillingIdentity, issuerLines } from "@/lib/remittance/terms";
import { saveBillingIdentity, saveBillingSettings } from "../../clients/actions";

type Settings = {
  invoice_prefix: string;
  own_bank_account_id: string | null;
  vat_on_debits: boolean;
  penalty_text: string;
  bank_cutoff: Record<string, string>;
  version: number;
};

/**
 * M2c-2 (design §17.5): the servicer's billing identity — what its invoices, statements and receipts print (C. com.
 * R123-237, R123-238; CGI ann. II 242 nonies A 1°–2°) — and its billing settings: invoice prefix, the own account due
 * invoices are paid to, VAT on debits (242 nonies A 11° bis), the late-payment penalty text (C. com. L441-10 II), the
 * bank's cut-off per dedicated account. Admins edit; ops managers read the settings; every staff member reads the
 * identity. Receipts issued from now on carry the identity block (template quittance-fr-3).
 */
export default async function BillingSettingsPage() {
  const { supabase, claims } = await staffSession();
  const { data: memberships } = await supabase
    .from("membership")
    .select("organization_id, role, organization:organization_id(kind, legal_name, siren)")
    .eq("user_id", claims.sub ?? "");
  const staff = (memberships ?? []).find((m) => m.organization?.kind === "servicer");
  if (!staff || !staff.organization) {
    return (
      <WidePage title="Facturation" back={{ href: "/backoffice", label: "Back-office" }}>
        <InfoNote>Réservé au personnel du cabinet.</InfoNote>
      </WidePage>
    );
  }
  const org = staff.organization_id;
  const isAdmin = staff.role === "admin";
  const [{ data: identityRow }, { data: settingsRow }, { data: gaps }, { data: accounts }] = await Promise.all([
    // the capital as text: integer minor units never pass through a JS number (review M2c-2)
    supabase.from("billing_identity").select(BILLING_IDENTITY_COLUMNS).eq("organization_id", org).maybeSingle(),
    supabase.from("servicer_billing_settings").select("*").eq("organization_id", org).maybeSingle(),
    supabase.rpc("billing_identity_gaps", { p_organization_id: org }),
    supabase.from("bank_account").select("id, label, iban, purpose, status, currency").eq("status", "active").order("label"),
  ]);
  const identity = identityRow as unknown as BillingIdentity | null;
  const settings = settingsRow as unknown as Settings | null;
  const missing = (gaps ?? []) as string[];
  const canReadSettings = isAdmin || staff.role === "ops_manager";
  const own = (accounts ?? []).filter((a) => a.purpose === "own");
  const dedicated = (accounts ?? []).filter((a) => a.purpose === "client_funds");

  return (
    <WidePage title="Facturation" back={{ href: "/backoffice", label: "Back-office" }}>
      <Section title="Identité du cabinet" testId="servicer-identity">
        {missing.length === 0 ? (
          <div className="flex flex-col items-start gap-2">
            <Badge tone="ok">Complète</Badge>
            <p className="text-sm text-zinc-600 dark:text-zinc-400">
              En-tête des quittances, relevés et factures (art. R123-237 et R123-238 C. com.) :
            </p>
            <div className="rounded-md border border-zinc-200 p-3 text-sm dark:border-zinc-800" data-testid="issuer-preview">
              {issuerLines(staff.organization.legal_name, staff.organization.siren, identity).map((l) => (
                <p key={l}>{l}</p>
              ))}
              {identity?.vat_number ? <p>TVA intracommunautaire {identity.vat_number}</p> : null}
            </div>
          </div>
        ) : (
          <InfoNote>
            <span data-testid="identity-gaps">
              À compléter : {missing.map((g) => GAP_LABEL[g] ?? g).join(", ")}. Aucun portefeuille ne peut être confirmé tant
              que l&apos;identité du cabinet est incomplète.
            </span>
          </InfoNote>
        )}
        {isAdmin ? (
          <details className="mt-3 rounded-md border border-zinc-200 p-3 dark:border-zinc-800" open={missing.length > 0}>
            <summary className="cursor-pointer text-sm font-medium">Modifier l&apos;identité</summary>
            <ActionForm
              action={saveBillingIdentity}
              submitLabel="Enregistrer l'identité"
              pendingLabel="Enregistrement…"
              buttonClassName={buttonClass}
              className="mt-3 flex max-w-2xl flex-col gap-4"
              testId="servicer-identity-form"
            >
              <input type="hidden" name="organization_id" value={org} readOnly />
              <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
              <IdentityFields
                kind="servicer"
                legalName={staff.organization.legal_name}
                siren={staff.organization.siren}
                identity={identity}
              />
            </ActionForm>
          </details>
        ) : null}
      </Section>

      {canReadSettings ? (
        <Section title="Paramètres de facturation" testId="billing-settings">
          <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
            <dt className="text-zinc-600 dark:text-zinc-400">Numérotation</dt>
            <dd data-testid="invoice-prefix">
              {settings?.invoice_prefix ?? "FC"}-{new Date().getFullYear()}-000001 (une série par année, factures et avoirs)
            </dd>
            <dt className="text-zinc-600 dark:text-zinc-400">Factures payables sur</dt>
            <dd>{own.find((a) => a.id === settings?.own_bank_account_id)?.label ?? "non choisi"}</dd>
            <dt className="text-zinc-600 dark:text-zinc-400">TVA</dt>
            <dd>{settings?.vat_on_debits ? "Option pour le paiement de la taxe d'après les débits" : "Sur les encaissements"}</dd>
            <dt className="text-zinc-600 dark:text-zinc-400">Pénalités</dt>
            <dd>
              {settings?.penalty_text ??
                "Taux de la BCE majoré de 10 points (par défaut, art. L441-10 II C. com.)"}{" "}
              Indemnité forfaitaire pour frais de recouvrement : 40 €.
            </dd>
          </dl>
          {isAdmin ? (
            <details className="mt-3 rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
              <summary className="cursor-pointer text-sm font-medium">Modifier les paramètres</summary>
              <ActionForm
                action={saveBillingSettings}
                submitLabel="Enregistrer les paramètres"
                pendingLabel="Enregistrement…"
                buttonClassName={buttonClass}
                className="mt-3 flex max-w-2xl flex-col gap-4"
                testId="billing-settings-form"
              >
                <input type="hidden" name="organization_id" value={org} readOnly />
                <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                <input type="hidden" name="expected_version" value={settings?.version ?? ""} readOnly />
                <label className="flex flex-col gap-1 text-sm">
                  Préfixe des factures (2 à 6 lettres)
                  <input
                    name="invoice_prefix"
                    maxLength={6}
                    defaultValue={settings?.invoice_prefix ?? "FC"}
                    autoCapitalize="characters"
                    className={inputClass}
                  />
                </label>
                <label className="flex flex-col gap-1 text-sm">
                  Compte propre recevant le paiement des factures
                  <select name="own_bank_account_id" defaultValue={settings?.own_bank_account_id ?? ""} className={inputClass}>
                    <option value="">—</option>
                    {own.map((a) => (
                      <option key={a.id} value={a.id}>
                        {a.label} · …{a.iban.slice(-4)}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="flex items-start gap-2 text-sm">
                  <input type="checkbox" name="vat_on_debits" defaultChecked={settings?.vat_on_debits ?? false} className="mt-1" />
                  <span>Option pour le paiement de la TVA d&apos;après les débits</span>
                </label>
                <label className="flex flex-col gap-1 text-sm">
                  Mention des pénalités de retard (vide : taux de la BCE majoré de 10 points, art. L441-10 II C. com. ; un taux
                  convenu ne peut être inférieur à trois fois le taux d&apos;intérêt légal)
                  <textarea name="penalty_text" rows={3} maxLength={500} defaultValue={settings?.penalty_text ?? ""} className={inputClass} />
                </label>
                {dedicated.map((a) => (
                  <label key={a.id} className="flex flex-col gap-1 text-sm">
                    Heure limite de remise des virements (heure de Paris) · {a.label}
                    <input type="time" name={`cutoff_${a.id}`} defaultValue={settings?.bank_cutoff?.[a.id] ?? ""} className={inputClass} />
                  </label>
                ))}
              </ActionForm>
            </details>
          ) : (
            <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">Seuls les administrateurs modifient ces paramètres.</p>
          )}
        </Section>
      ) : null}
    </WidePage>
  );
}
