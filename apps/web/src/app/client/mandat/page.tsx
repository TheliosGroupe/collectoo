import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { ActionForm } from "@/components/action-form";
import { Badge, InfoNote, Page, buttonClass, dangerButtonClass, inputClass } from "@/components/ui";
import type { SessionClaims } from "@/lib/auth/access";
import { frenchDate } from "@/lib/payments/bank-accounts";
import { CONFIRMED_VIA, PAYOUT_STATUS, addressText, scheduleInWords, termsInWords, type Address } from "@/lib/remittance/terms";
import { createClient } from "@/lib/supabase/server";
import { confirmOwnPayoutAccount, rejectOwnPayoutAccount } from "./actions";

type Payout = {
  id: string;
  currency: string;
  iban_masked: string;
  holder_name: string;
  kind: string;
  status: string;
  proposed_at: string;
  confirmed_at: string | null;
  confirmed_via: string | null;
  evidence_document_id: string;
};

function parisToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
}

/**
 * M2c-2 (design §17.7): the client's mandate and payout account. The money terms in force (R124-3 3°, 4°) in words,
 * the payout IBAN masked, and — for the client's administrator with access to the whole client, at aal2 — « Confirmer
 * le nouvel IBAN » proposed by the servicer (founder #10: the client confirms, typing the IBAN read on its RIB). Users
 * restricted to some portfolios read no client-level data (OQ-48 default).
 */
export default async function ClientMandatePage() {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  const claims = (data?.claims ?? null) as SessionClaims | null;
  if (!claims?.sub) redirect("/connexion");

  const [{ data: memberships }, { data: access }] = await Promise.all([
    supabase.from("membership").select("organization_id, role, organization:organization_id(kind, legal_name, siren)").eq("user_id", claims.sub),
    supabase.from("portfolio_access").select("portfolio_id").eq("user_id", claims.sub).limit(1),
  ]);
  const member = (memberships ?? []).find((m) => m.organization?.kind !== "servicer");
  const restricted = (access ?? []).length > 0;
  if (!member || !member.organization) {
    return (
      <Page title="Mandat et reversements">
        <InfoNote>Aucun client rattaché à votre compte.</InfoNote>
      </Page>
    );
  }
  if (restricted) {
    return (
      <Page title="Mandat et reversements">
        <InfoNote>Vos accès ne couvrent pas le mandat ni les reversements : ils portent sur tous les portefeuilles du client.</InfoNote>
        <Link href="/client" className="text-sm underline underline-offset-4">
          Retour à l&apos;espace client
        </Link>
      </Page>
    );
  }
  const org = member.organization_id;
  const isAdmin = member.role === "client_admin";
  const [{ data: identityRow }, { data: mandates }, payoutRes] = await Promise.all([
    supabase.from("billing_identity").select("registered_office, billing_address").eq("organization_id", org).maybeSingle(),
    supabase
      .from("mandate")
      .select("id, reference, signed_on, insurance_clause_ref, mandate_terms(*)")
      .eq("client_organization_id", org)
      .order("signed_on"),
    isAdmin ? supabase.rpc("payout_accounts", { p_client_organization_id: org }) : Promise.resolve({ data: [] }),
  ]);
  const payouts = (payoutRes.data ?? []) as Payout[];
  const today = parisToday();
  const aal2 = claims.aal === "aal2";

  return (
    <Page title="Mandat et reversements">
      <p className="text-sm text-zinc-600 dark:text-zinc-400">
        {member.organization.legal_name}
        {member.organization.siren ? ` · SIREN ${member.organization.siren}` : ""}
        {identityRow?.registered_office ? ` · ${addressText(identityRow.registered_office as unknown as Address)}` : ""}
      </p>

      {isAdmin ? (
        <section className="flex flex-col gap-3 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800" data-testid="client-payout">
          <h2 className="font-medium">Compte de reversement</h2>
          {payouts.length === 0 ? (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun IBAN de reversement enregistré par le cabinet.</p>
          ) : (
            payouts
              .filter((p) => p.status === "proposed" || p.status === "active" || p.status === "returned")
              .map((p) => (
                <div key={p.id} className="flex flex-col gap-2" data-testid="client-payout-account">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-mono">{p.iban_masked}</span>
                    <Badge tone={p.status === "active" ? "ok" : "action"}>{PAYOUT_STATUS[p.status] ?? p.status}</Badge>
                  </div>
                  <p className="text-sm text-zinc-600 dark:text-zinc-400">
                    Titulaire : {p.holder_name}
                    {p.confirmed_at ? ` · confirmé ${CONFIRMED_VIA[p.confirmed_via ?? ""] ?? ""}` : ""} ·{" "}
                    <a href={`/client/documents/${p.evidence_document_id}`} className="underline underline-offset-4">
                      RIB transmis
                    </a>
                  </p>
                  {p.status === "proposed" && p.kind === "client" ? (
                    aal2 ? (
                      <>
                        <ActionForm
                          action={confirmOwnPayoutAccount}
                          submitLabel="Confirmer le nouvel IBAN"
                          pendingLabel="Confirmation…"
                          buttonClassName={buttonClass}
                          className="flex flex-col gap-2"
                          testId="client-confirm-payout"
                        >
                          <input type="hidden" name="payout_account_id" value={p.id} readOnly />
                          <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                          <p className="text-sm">
                            Le cabinet propose de vous reverser vos encaissements sur ce compte. Saisissez l&apos;IBAN tel qu&apos;il
                            figure sur votre RIB : il doit être identique.
                          </p>
                          <label className="flex flex-col gap-1 text-sm">
                            IBAN de votre RIB
                            <input name="iban_typed" required autoComplete="off" spellCheck={false} className={`${inputClass} font-mono`} />
                          </label>
                        </ActionForm>
                        <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                          <summary className="cursor-pointer text-sm font-medium">Ce n&apos;est pas notre compte</summary>
                          <ActionForm
                            action={rejectOwnPayoutAccount}
                            submitLabel="Refuser cet IBAN"
                            pendingLabel="Enregistrement…"
                            buttonClassName={dangerButtonClass}
                            className="mt-3 flex flex-col gap-2"
                          >
                            <input type="hidden" name="payout_account_id" value={p.id} readOnly />
                            <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                            <label className="flex flex-col gap-1 text-sm">
                              Motif
                              <input name="reason" required maxLength={2000} className={inputClass} />
                            </label>
                          </ActionForm>
                        </details>
                      </>
                    ) : (
                      <InfoNote>
                        Un nouvel IBAN attend votre confirmation. Pour le confirmer,{" "}
                        <Link href="/mfa?next=/client/mandat" className="underline underline-offset-4" data-testid="client-mfa-link">
                          activez la double authentification
                        </Link>
                        .
                      </InfoNote>
                    )
                  ) : null}
                </div>
              ))
          )}
        </section>
      ) : null}

      <section className="flex flex-col gap-3 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800" data-testid="client-terms">
        <h2 className="font-medium">Conditions de votre mandat</h2>
        {(mandates ?? []).length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun mandat.</p>
        ) : (
          (mandates ?? []).map((m) => {
            const versions = [...(m.mandate_terms ?? [])].sort((a, b) => a.valid_from.localeCompare(b.valid_from));
            const current = versions.filter((v) => v.valid_from <= today && (!v.valid_to || v.valid_to > today)).at(-1);
            const next = versions.find((v) => v.valid_from > today);
            return (
              <article key={m.id} className="flex flex-col gap-2 text-sm">
                <p className="font-medium">
                  Mandat {m.reference} · signé le {frenchDate(m.signed_on)}
                </p>
                {current ? (
                  <>
                    <p className="text-zinc-600 dark:text-zinc-400">
                      En vigueur depuis le {frenchDate(current.valid_from)} · rémunération : {current.commission_clause_ref ?? "—"} ·
                      reversements : {current.remittance_clause_ref ?? "—"}
                    </p>
                    <ul className="list-disc pl-5">
                      {scheduleInWords(current.commission_schedule).map((l) => (
                        <li key={l}>{l}</li>
                      ))}
                      {termsInWords(current.remittance_terms, current.remittance_max_days).map((l) => (
                        <li key={l}>{l}</li>
                      ))}
                    </ul>
                    {isAdmin && current.document_id ? (
                      <a href={`/client/documents/${current.document_id}`} className="underline underline-offset-4">
                        Mandat signé
                      </a>
                    ) : null}
                  </>
                ) : (
                  <p className="text-zinc-600 dark:text-zinc-400">Aucune condition en vigueur aujourd&apos;hui.</p>
                )}
                {next ? <p className="text-zinc-600 dark:text-zinc-400">Nouvelles conditions à partir du {frenchDate(next.valid_from)}.</p> : null}
              </article>
            );
          })
        )}
      </section>
      <Link href="/client" className="text-sm underline underline-offset-4">
        Retour à l&apos;espace client
      </Link>
    </Page>
  );
}
