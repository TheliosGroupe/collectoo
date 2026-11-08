import { randomUUID } from "node:crypto";
import { ActionForm } from "@/components/action-form";
import { Badge, InfoNote, Section, WidePage, buttonClass, dangerButtonClass, inputClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { FEED_LABEL, frenchDate } from "@/lib/payments/bank-accounts";
import { groupsOfFour } from "@/lib/payments/iban";
import { closeBankAccount, registerBankAccount } from "./actions";

/**
 * M2b-1: the servicer's bank accounts. The account dedicated to funds collected for creditors
 * (CPCE R124-2) is the only place debtor payments are booked. Admins add and close accounts;
 * ops managers read them; nobody else sees them (RLS).
 */
export default async function BankAccountsPage() {
  const { supabase, claims } = await staffSession();
  const [{ data: memberships }, { data: accounts }, { data: currencies }] = await Promise.all([
    supabase
      .from("membership")
      .select("organization_id, role, organization:organization_id(kind)")
      .eq("user_id", claims.sub ?? ""),
    supabase
      .from("bank_account")
      .select("id, label, iban, bic, currency, feed, status, opened_on, closed_on, closed_reason")
      .order("status")
      .order("label"),
    supabase.from("currency").select("code, label_fr").order("code"),
  ]);
  const staff = (memberships ?? []).find((m) => m.organization?.kind === "servicer");
  const isAdmin = staff?.role === "admin";
  const canRead = isAdmin || staff?.role === "ops_manager";
  // Business calendar Europe/Paris, as yyyy-mm-dd.
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());

  return (
    <WidePage title="Comptes bancaires" back={{ href: "/backoffice", label: "Back-office" }}>
      <InfoNote>
        Le compte dédié aux fonds de tiers reçoit exclusivement les fonds encaissés pour le compte des créanciers (art. R124-2
        CPCE). Seuls ses relevés sont importés et comptabilisés.
      </InfoNote>

      {!canRead ? (
        <InfoNote>Les comptes bancaires sont réservés aux administrateurs et aux responsables des opérations.</InfoNote>
      ) : (accounts ?? []).length === 0 ? (
        <InfoNote>Aucun compte bancaire enregistré pour l&apos;instant.</InfoNote>
      ) : (
        <ul className="grid gap-4 sm:grid-cols-2" data-testid="bank-accounts">
          {(accounts ?? []).map((a) => (
            <li key={a.id} className="flex flex-col gap-3 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="font-medium">{a.label}</p>
                  <p className="text-sm text-zinc-600 dark:text-zinc-400">Fonds de tiers · {a.currency}</p>
                </div>
                {a.status === "active" ? <Badge tone="ok">Actif</Badge> : <Badge tone="neutral">Clôturé</Badge>}
              </div>
              <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
                <dt className="text-zinc-600 dark:text-zinc-400">IBAN</dt>
                <dd className="font-mono" data-testid="iban">
                  {groupsOfFour(a.iban)}
                </dd>
                {a.bic ? (
                  <>
                    <dt className="text-zinc-600 dark:text-zinc-400">BIC</dt>
                    <dd className="font-mono">{a.bic}</dd>
                  </>
                ) : null}
                <dt className="text-zinc-600 dark:text-zinc-400">Relevés</dt>
                <dd>{FEED_LABEL[a.feed] ?? a.feed}</dd>
                <dt className="text-zinc-600 dark:text-zinc-400">Ouvert le</dt>
                <dd>{frenchDate(a.opened_on)}</dd>
                {a.status === "closed" ? (
                  <>
                    <dt className="text-zinc-600 dark:text-zinc-400">Clôturé le</dt>
                    <dd data-testid="closed-on">
                      {frenchDate(a.closed_on)} · {a.closed_reason}
                    </dd>
                  </>
                ) : null}
              </dl>
              {isAdmin && a.status === "active" ? (
                <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                  <summary className="cursor-pointer text-sm font-medium">Clôturer ce compte</summary>
                  <ActionForm
                    action={closeBankAccount}
                    submitLabel="Clôturer le compte"
                    pendingLabel="Clôture…"
                    buttonClassName={dangerButtonClass}
                    className="mt-3 flex flex-col gap-2"
                  >
                    <input type="hidden" name="bank_account_id" value={a.id} readOnly />
                    <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                    <p className="text-sm text-zinc-600 dark:text-zinc-400">
                      Possible seulement si le compte ne détient plus de fonds de tiers (solde nul). Ses relevés ne seront plus
                      acceptés.
                    </p>
                    <label className="flex flex-col gap-1 text-sm">
                      Motif de la clôture
                      <input name="reason" required maxLength={2000} className={inputClass} />
                    </label>
                    <label className="flex flex-col gap-1 text-sm">
                      La clôture est définitive : saisissez les 4 derniers caractères de l&apos;IBAN
                      <input name="confirm_iban" required maxLength={8} autoComplete="off" className={inputClass} />
                    </label>
                  </ActionForm>
                </details>
              ) : null}
            </li>
          ))}
        </ul>
      )}

      {isAdmin && staff ? (
        <Section title="Ajouter un compte de fonds de tiers" testId="add-bank-account">
          <ActionForm
            action={registerBankAccount}
            submitLabel="Ajouter le compte"
            pendingLabel="Enregistrement…"
            buttonClassName={buttonClass}
            className="flex max-w-xl flex-col gap-4"
            resetOnSuccess
          >
            <input type="hidden" name="organization_id" value={staff.organization_id} readOnly />
            <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
            <label className="flex flex-col gap-1 text-sm">
              Libellé
              <input name="label" required maxLength={100} placeholder="Fonds de tiers – Banque" className={inputClass} />
            </label>
            <label className="flex flex-col gap-1 text-sm">
              IBAN
              <input
                name="iban"
                required
                autoComplete="off"
                spellCheck={false}
                autoCapitalize="characters"
                placeholder="FR76 3000 4000 0312 3456 7890 143"
                className={`${inputClass} font-mono`}
              />
            </label>
            <div className="grid gap-4 sm:grid-cols-2">
              <label className="flex flex-col gap-1 text-sm">
                BIC (facultatif)
                <input
                  name="bic"
                  autoComplete="off"
                  spellCheck={false}
                  autoCapitalize="characters"
                  maxLength={11}
                  className={`${inputClass} font-mono`}
                />
              </label>
              <label className="flex flex-col gap-1 text-sm">
                Devise
                <select name="currency" defaultValue="EUR" className={inputClass}>
                  {(currencies ?? []).map((c) => (
                    <option key={c.code} value={c.code}>
                      {c.code} – {c.label_fr}
                    </option>
                  ))}
                </select>
              </label>
              <label className="flex flex-col gap-1 text-sm">
                Format des relevés
                <select name="feed" defaultValue="camt053" className={inputClass}>
                  <option value="camt053">{FEED_LABEL.camt053} – recommandé</option>
                  <option value="csv">{FEED_LABEL.csv}</option>
                </select>
              </label>
              <label className="flex flex-col gap-1 text-sm">
                Date d&apos;ouverture
                <input type="date" name="opened_on" defaultValue={today} max={today} className={inputClass} />
              </label>
            </div>
          </ActionForm>
        </Section>
      ) : canRead ? (
        <p className="text-sm text-zinc-600 dark:text-zinc-400">Seuls les administrateurs ajoutent ou clôturent un compte.</p>
      ) : null}
    </WidePage>
  );
}
