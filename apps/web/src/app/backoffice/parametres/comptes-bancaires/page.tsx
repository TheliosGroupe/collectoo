import { randomUUID } from "node:crypto";
import { ActionForm } from "@/components/action-form";
import { Badge, InfoNote, Section, WidePage, buttonClass, dangerButtonClass, inputClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { FEED_LABEL, PURPOSE_LABEL, TOP_UP_STATUS, frenchDate } from "@/lib/payments/bank-accounts";
import { groupsOfFour } from "@/lib/payments/iban";
import { money } from "@/lib/payments/statements";
import { cancelTopUp, closeBankAccount, registerBankAccount, requestTopUp } from "./actions";

type Account = {
  id: string;
  label: string;
  iban: string;
  bic: string | null;
  currency: string;
  purpose: string;
  feed: string | null;
  status: string;
  opened_on: string;
  closed_on: string | null;
  closed_reason: string | null;
};
type TopUp = {
  id: string;
  debtor_bank_account_id: string;
  creditor_bank_account_id: string | null;
  amount_minor: number | string;
  currency: string;
  end_to_end_id: string;
  status: string;
  requested_execution_date: string;
  reason: string | null;
};

/**
 * M2b-1, M2c-1: the servicer's bank accounts. The account dedicated to funds collected for creditors (CPCE R124-2,
 * one active per currency) is the only place debtor payments are booked; the servicer's own account (« compte propre »)
 * receives its commission and tops the dedicated account up when the servicer owes it (a bank fee, a return after
 * remittance). Admins add and close accounts; admins and ops managers order top-ups; nobody else sees them (RLS).
 */
export default async function BankAccountsPage() {
  const { supabase, claims } = await staffSession();
  const [{ data: memberships }, { data: accountRows }, { data: currencies }, { data: topUpRows }] = await Promise.all([
    supabase
      .from("membership")
      .select("organization_id, role, organization:organization_id(kind)")
      .eq("user_id", claims.sub ?? ""),
    supabase
      .from("bank_account")
      .select("id, label, iban, bic, currency, purpose, feed, status, opened_on, closed_on, closed_reason")
      .order("status")
      .order("purpose")
      .order("label"),
    supabase.from("currency").select("code, label_fr").order("code"),
    supabase
      .from("bank_transfer")
      .select(
        "id, debtor_bank_account_id, creditor_bank_account_id, amount_minor, currency, end_to_end_id, status, requested_execution_date, reason",
      )
      .eq("kind", "top_up")
      .order("created_at", { ascending: false })
      .limit(20),
  ]);
  const accounts = (accountRows ?? []) as Account[];
  const topUps = (topUpRows ?? []) as TopUp[];
  const staff = (memberships ?? []).find((m) => m.organization?.kind === "servicer");
  const isAdmin = staff?.role === "admin";
  const canRead = isAdmin || staff?.role === "ops_manager";
  // Business calendar Europe/Paris, as yyyy-mm-dd.
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
  const byId = new Map(accounts.map((a) => [a.id, a]));
  const dedicated = accounts.filter((a) => a.purpose === "client_funds" && a.status === "active");

  return (
    <WidePage title="Comptes bancaires" back={{ href: "/backoffice", label: "Back-office" }}>
      <InfoNote>
        Le compte dédié aux fonds de tiers reçoit exclusivement les fonds encaissés pour le compte des créanciers (art. R124-2
        CPCE) : un seul par devise, dont seuls les relevés sont importés et comptabilisés. Le compte propre du cabinet reçoit
        ses commissions et approvisionne le compte dédié quand le cabinet lui doit de l&apos;argent (frais bancaires, retour
        après reversement).
      </InfoNote>

      {!canRead ? (
        <InfoNote>Les comptes bancaires sont réservés aux administrateurs et aux responsables des opérations.</InfoNote>
      ) : accounts.length === 0 ? (
        <InfoNote>Aucun compte bancaire enregistré pour l&apos;instant.</InfoNote>
      ) : (
        <ul className="grid gap-4 sm:grid-cols-2" data-testid="bank-accounts">
          {accounts.map((a) => (
            <li key={a.id} className="flex flex-col gap-3 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800" data-testid="bank-account">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="font-medium">{a.label}</p>
                  <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="purpose">
                    {PURPOSE_LABEL[a.purpose] ?? a.purpose} · {a.currency}
                  </p>
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
                <dd>{a.feed ? (FEED_LABEL[a.feed] ?? a.feed) : "Non importés (compte propre)"}</dd>
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
              {a.purpose === "own" && a.status === "active" && canRead
                ? dedicated
                    .filter((d) => d.currency === a.currency)
                    .map((d) => (
                      <details key={d.id} className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800" data-testid="top-up">
                        <summary className="cursor-pointer text-sm font-medium">Approvisionner « {d.label} »</summary>
                        <ActionForm
                          action={requestTopUp}
                          submitLabel="Demander l'approvisionnement"
                          pendingLabel="Enregistrement…"
                          buttonClassName={buttonClass}
                          className="mt-3 flex flex-col gap-2"
                          resetOnSuccess
                        >
                          <input type="hidden" name="own_bank_account_id" value={a.id} readOnly />
                          <input type="hidden" name="client_funds_bank_account_id" value={d.id} readOnly />
                          <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                          <p className="text-sm text-zinc-600 dark:text-zinc-400">
                            Une référence TOP… est attribuée : saisissez-la comme référence de bout en bout du virement
                            dans la banque. L&apos;approvisionnement est comptabilisé quand son crédit apparaît sur le relevé du
                            compte dédié.
                          </p>
                          <label className="flex flex-col gap-1 text-sm">
                            Montant ({a.currency})
                            <input name="amount" required inputMode="decimal" placeholder="200,00" className={inputClass} />
                          </label>
                          <label className="flex flex-col gap-1 text-sm">
                            Motif (interne)
                            <input name="reason" required maxLength={2000} placeholder="Frais bancaires du mois" className={inputClass} />
                          </label>
                        </ActionForm>
                      </details>
                    ))
                : null}
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
                      {a.purpose === "own"
                        ? "Possible seulement si aucun approvisionnement depuis ce compte n'est en cours."
                        : "Possible seulement si le compte ne détient plus de fonds de tiers (solde nul). Ses relevés ne seront plus acceptés."}
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

      {canRead && topUps.length > 0 ? (
        <Section title="Approvisionnements du compte dédié" testId="top-ups">
          <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
            {topUps.map((t) => (
              <li key={t.id} className="flex flex-col gap-1 py-3" data-testid="top-up-row">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="font-mono text-sm break-all" data-testid="top-up-ref">
                    {t.end_to_end_id}
                  </span>
                  <span className="font-medium tabular-nums">{money(String(t.amount_minor), t.currency)}</span>
                </div>
                <p className="text-sm text-zinc-600 dark:text-zinc-400">
                  {byId.get(t.debtor_bank_account_id)?.label ?? "Compte propre"} →{" "}
                  {byId.get(t.creditor_bank_account_id ?? "")?.label ?? "Compte dédié"} · exécution demandée le{" "}
                  {frenchDate(t.requested_execution_date)}
                  {t.reason ? ` · ${t.reason}` : ""}
                </p>
                <span className="flex flex-wrap items-center gap-2">
                  <Badge tone={t.status === "ordered" ? "action" : t.status === "booked" ? "ok" : "neutral"}>
                    {TOP_UP_STATUS[t.status] ?? t.status}
                  </Badge>
                </span>
                {t.status === "ordered" ? (
                  <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                    <summary className="cursor-pointer text-sm font-medium">Annuler</summary>
                    <ActionForm
                      action={cancelTopUp}
                      submitLabel="Annuler l'approvisionnement"
                      pendingLabel="Annulation…"
                      buttonClassName={dangerButtonClass}
                      className="mt-3 flex flex-col gap-2"
                    >
                      <input type="hidden" name="transfer_id" value={t.id} readOnly />
                      <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                      <label className="flex flex-col gap-1 text-sm">
                        Motif (non envoyé, refusé par la banque…)
                        <input name="reason" required maxLength={2000} className={inputClass} />
                      </label>
                    </ActionForm>
                  </details>
                ) : null}
              </li>
            ))}
          </ul>
        </Section>
      ) : null}

      {isAdmin && staff ? (
        <>
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
              <input type="hidden" name="purpose" value="client_funds" readOnly />
              <AccountFields currencies={currencies ?? []} today={today} labelPlaceholder="Fonds de tiers – Banque" />
              <label className="flex flex-col gap-1 text-sm">
                Format des relevés
                <select name="feed" defaultValue="camt053" className={inputClass}>
                  <option value="camt053">{FEED_LABEL.camt053} – recommandé</option>
                  <option value="csv">{FEED_LABEL.csv}</option>
                </select>
              </label>
            </ActionForm>
          </Section>
          <Section title="Ajouter le compte propre du cabinet" testId="add-own-account">
            <ActionForm
              action={registerBankAccount}
              submitLabel="Ajouter le compte propre"
              pendingLabel="Enregistrement…"
              buttonClassName={buttonClass}
              className="flex max-w-xl flex-col gap-4"
              resetOnSuccess
            >
              <input type="hidden" name="organization_id" value={staff.organization_id} readOnly />
              <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
              <input type="hidden" name="purpose" value="own" readOnly />
              <p className="text-sm text-zinc-600 dark:text-zinc-400">
                Le compte d&apos;exploitation du cabinet : ses relevés ne sont pas importés. Un crédit venant de cet IBAN sur
                le compte dédié n&apos;est jamais pris pour le paiement d&apos;un débiteur.
              </p>
              <AccountFields currencies={currencies ?? []} today={today} labelPlaceholder="Compte propre – Banque" />
            </ActionForm>
          </Section>
        </>
      ) : canRead ? (
        <p className="text-sm text-zinc-600 dark:text-zinc-400">Seuls les administrateurs ajoutent ou clôturent un compte.</p>
      ) : null}
    </WidePage>
  );
}

function AccountFields({
  currencies,
  today,
  labelPlaceholder,
}: {
  currencies: { code: string; label_fr: string }[];
  today: string;
  labelPlaceholder: string;
}) {
  return (
    <>
      <label className="flex flex-col gap-1 text-sm">
        Libellé
        <input name="label" required maxLength={100} placeholder={labelPlaceholder} className={inputClass} />
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
            {currencies.map((c) => (
              <option key={c.code} value={c.code}>
                {c.code} – {c.label_fr}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Date d&apos;ouverture
          <input type="date" name="opened_on" defaultValue={today} max={today} className={inputClass} />
        </label>
      </div>
    </>
  );
}
