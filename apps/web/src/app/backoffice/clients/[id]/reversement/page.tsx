import { randomUUID } from "node:crypto";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ActionForm } from "@/components/action-form";
import { IdentityFields } from "@/components/identity-fields";
import { Badge, InfoNote, Section, WidePage, buttonClass, dangerButtonClass, inputClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { frenchDate } from "@/lib/payments/bank-accounts";
import {
  type BillingIdentity,
  CONFIRMED_VIA,
  DOCUMENT_KIND,
  EVENT_KIND,
  GAP_LABEL,
  PAYOUT_STATUS,
  READINESS_LABEL,
  addressText,
  scheduleInWords,
  termsInWords,
} from "@/lib/remittance/terms";
import {
  confirmPayoutAccount,
  proposePayoutAccount,
  recordClientEvent,
  rejectPayoutAccount,
  retirePayoutAccount,
  saveBillingIdentity,
  setInsuranceClause,
  setMandateTerms,
} from "../../actions";
import { ClientDocumentUpload } from "./document-upload";

type Payout = {
  id: string;
  currency: string;
  iban_masked: string;
  holder_name: string;
  bic: string | null;
  kind: string;
  status: string;
  proposed_at: string;
  proposed_by_name: string | null;
  proposed_by_me: boolean;
  confirmed_at: string | null;
  confirmed_via: string | null;
  confirmed_by_name: string | null;
  closed_reason: string | null;
  evidence_document_id: string;
  paid_before: boolean;
};
type Terms = {
  id: string;
  mandate_id: string;
  valid_from: string;
  valid_to: string | null;
  remittance_max_days: number;
  commission_schedule: unknown;
  commission_clause_ref: string | null;
  remittance_terms: unknown;
  remittance_clause_ref: string | null;
  document_id: string | null;
  schedule_sha256: string | null;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const SCHEDULE_TEMPLATE = {
  schema: "commission-1",
  basis: {
    families: "all",
    forwards: { file_recalled: false, before_servicing_start: false, client_ratification: false },
    on_reversal: "credit",
  },
  rules: [{ id: "tout", tier_key: "tout", label_fr: "Toutes créances", match: {}, rate: { kind: "flat", rate: "0.15" } }],
};

function parisToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
}

function frenchDateTime(iso: string | null): string {
  if (!iso) return "";
  return new Intl.DateTimeFormat("fr-FR", { timeZone: "Europe/Paris", dateStyle: "short", timeStyle: "short" }).format(new Date(iso));
}

/**
 * M2c-2 (design §17.4): one client's billing identity, its documents, its payout IBAN under dual control (founder #10: a
 * second person confirms — the client's administrator in the client space, or another admin of the servicer, typing
 * the IBAN read on the RIB), the money terms of its mandates (R124-3 2°–4°, versions in words) and its status events
 * (C. civ. 2003, C. com. L622-7, L641-9), with what still keeps each portfolio from being confirmed (§9.1).
 */
export default async function ClientRemittancePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const { supabase, claims } = await staffSession();
  const { data: client } = await supabase
    .from("organization")
    .select("id, legal_name, siren, kind, servicer_organization_id")
    .eq("id", id)
    .maybeSingle();
  if (!client || client.kind === "servicer" || !client.servicer_organization_id) notFound();
  const { data: memberships } = await supabase
    .from("membership")
    .select("role")
    .eq("user_id", claims.sub ?? "")
    .eq("organization_id", client.servicer_organization_id);
  const role = memberships?.[0]?.role ?? null;
  const isAdmin = role === "admin";
  const isMoney = isAdmin || role === "ops_manager";

  const [identityRes, gapsRes, readinessRes, payoutRes, docsRes, eventsRes, mandatesRes, claimTypesRes] = await Promise.all([
    supabase.from("billing_identity").select("*").eq("organization_id", id).maybeSingle(),
    supabase.rpc("billing_identity_gaps", { p_organization_id: id }),
    supabase.rpc("client_readiness", { p_client_organization_id: id }),
    isMoney ? supabase.rpc("payout_accounts", { p_client_organization_id: id }) : Promise.resolve({ data: [] }),
    supabase
      .from("document")
      .select("id, kind, file_name, created_at")
      .eq("client_organization_id", id)
      .in("kind", ["payout_rib", "mandate_document", "client_status_evidence"])
      .order("created_at", { ascending: false }),
    supabase
      .from("client_status_event")
      .select("id, kind, effective_date, note, evidence_document_id, recorded_at")
      .eq("client_organization_id", id)
      .order("effective_date", { ascending: false }),
    supabase
      .from("mandate")
      .select("id, reference, signed_on, insurance_clause_ref, mandate_terms(*)")
      .eq("client_organization_id", id)
      .order("signed_on"),
    supabase.from("claim_type").select("code, label_fr"),
  ]);
  const identity = identityRes.data as unknown as BillingIdentity | null;
  const gaps = (gapsRes.data ?? []) as string[];
  const readiness = (readinessRes.data ?? []) as { portfolio_id: string; portfolio_name: string; blockers: string[] }[];
  const payouts = (payoutRes.data ?? []) as Payout[];
  const docs = docsRes.data ?? [];
  const events = eventsRes.data ?? [];
  const mandates = (mandatesRes.data ?? []) as unknown as {
    id: string;
    reference: string;
    signed_on: string;
    insurance_clause_ref: string | null;
    mandate_terms: Terms[];
  }[];
  const claimLabels = Object.fromEntries((claimTypesRes.data ?? []).map((c) => [c.code, c.label_fr]));
  const today = parisToday();
  const ribs = docs.filter((d) => d.kind === "payout_rib");
  const mandateDocs = docs.filter((d) => d.kind === "mandate_document");
  const evidence = docs.filter((d) => d.kind === "client_status_evidence");
  const courtAccounts = payouts.filter((p) => p.kind === "court_appointed");
  const docName = new Map(docs.map((d) => [d.id, d.file_name ?? DOCUMENT_KIND[d.kind]]));

  return (
    <WidePage title={client.legal_name} back={{ href: "/backoffice/clients", label: "Clients" }}>
      <Section title="Prêt pour la confirmation des portefeuilles" testId="client-readiness">
        {readiness.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun portefeuille pour ce client.</p>
        ) : (
          <ul className="flex flex-col gap-3">
            {readiness.map((r) => (
              <li key={r.portfolio_id} className="flex flex-col gap-1" data-testid="portfolio-readiness">
                <span className="flex flex-wrap items-center gap-2">
                  <span className="font-medium">{r.portfolio_name}</span>
                  {r.blockers.length === 0 ? <Badge tone="ok">Prêt</Badge> : <Badge tone="action">À compléter</Badge>}
                </span>
                {r.blockers.length > 0 ? (
                  <ul className="list-disc pl-5 text-sm text-zinc-700 dark:text-zinc-300">
                    {r.blockers.map((b) => (
                      <li key={b}>{READINESS_LABEL[b] ?? b}</li>
                    ))}
                  </ul>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </Section>

      <Section title="Identité de facturation" testId="client-identity">
        {identity ? (
          <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
            <dt className="text-zinc-600 dark:text-zinc-400">SIREN</dt>
            <dd className="font-mono">{client.siren ?? "—"}</dd>
            <dt className="text-zinc-600 dark:text-zinc-400">Siège</dt>
            <dd>{addressText(identity.registered_office)}</dd>
            {identity.billing_address ? (
              <>
                <dt className="text-zinc-600 dark:text-zinc-400">Facturation</dt>
                <dd>{addressText(identity.billing_address)}</dd>
              </>
            ) : null}
            <dt className="text-zinc-600 dark:text-zinc-400">Factures PDF</dt>
            <dd>{identity.invoice_acceptance_ref ?? "non acceptées : envoi postal"}</dd>
          </dl>
        ) : null}
        {gaps.length > 0 ? (
          <div className="mt-2">
            <InfoNote>
              <span data-testid="client-identity-gaps">À compléter : {gaps.map((g) => GAP_LABEL[g] ?? g).join(", ")}.</span>
            </InfoNote>
          </div>
        ) : (
          <div className="mt-2">
            <Badge tone="ok">Complète</Badge>
          </div>
        )}
        {isAdmin ? (
          <details className="mt-3 rounded-md border border-zinc-200 p-3 dark:border-zinc-800" open={!identity}>
            <summary className="cursor-pointer text-sm font-medium">Modifier l&apos;identité</summary>
            <ActionForm
              action={saveBillingIdentity}
              submitLabel="Enregistrer l'identité"
              pendingLabel="Enregistrement…"
              buttonClassName={buttonClass}
              className="mt-3 flex max-w-2xl flex-col gap-4"
              testId="client-identity-form"
            >
              <input type="hidden" name="organization_id" value={id} readOnly />
              <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
              <IdentityFields kind="client" legalName={client.legal_name} siren={client.siren} identity={identity} />
            </ActionForm>
          </details>
        ) : null}
      </Section>

      {isMoney ? (
        <Section title="Documents du client" testId="client-documents">
          {docs.length === 0 ? (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun document joint.</p>
          ) : (
            <ul className="mb-3 flex flex-col gap-1 text-sm">
              {docs.map((d) => (
                <li key={d.id} data-testid="client-document">
                  {DOCUMENT_KIND[d.kind] ?? d.kind} ·{" "}
                  <a href={`/backoffice/documents/${d.id}`} className="underline underline-offset-4">
                    {d.file_name ?? "fichier"}
                  </a>{" "}
                  · {frenchDateTime(d.created_at)}
                </li>
              ))}
            </ul>
          )}
          <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
            <summary className="cursor-pointer text-sm font-medium">Joindre un document</summary>
            <div className="mt-3">
              <ClientDocumentUpload servicerId={client.servicer_organization_id} clientId={id} />
            </div>
          </details>
        </Section>
      ) : null}

      {isMoney ? (
        <Section title="Compte de reversement" testId="payout-accounts">
          <p className="mb-3 text-sm text-zinc-600 dark:text-zinc-400">
            L&apos;IBAN figure sur le RIB du client. Une seconde personne le confirme en saisissant l&apos;IBAN lu sur le RIB :
            l&apos;administrateur du client dans son espace, ou un autre administrateur du cabinet. Le premier virement vers un
            nouvel IBAN est signalé.
          </p>
          {payouts.length === 0 ? (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun IBAN de reversement.</p>
          ) : (
            <ul className="mb-3 flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
              {payouts.map((p) => (
                <li key={p.id} className="flex flex-col gap-2 py-3" data-testid="payout-account">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-mono" data-testid="payout-iban">
                      {p.iban_masked}
                    </span>
                    <span className="flex flex-wrap gap-2">
                      <Badge tone={p.status === "active" ? "ok" : p.status === "proposed" ? "action" : "neutral"} testId="payout-status">
                        {PAYOUT_STATUS[p.status] ?? p.status}
                      </Badge>
                      {p.status === "active" && !p.paid_before ? <Badge tone="action">Nouvel IBAN : premier virement à vérifier</Badge> : null}
                    </span>
                  </div>
                  <p className="text-sm text-zinc-600 dark:text-zinc-400">
                    {p.holder_name} · {p.currency}
                    {p.kind === "court_appointed" ? " · mandataire de justice" : ""} · proposé par {p.proposed_by_name ?? "—"} le{" "}
                    {frenchDateTime(p.proposed_at)}
                    {p.confirmed_at
                      ? ` · confirmé ${CONFIRMED_VIA[p.confirmed_via ?? ""] ?? ""} (${p.confirmed_by_name ?? "—"}) le ${frenchDateTime(p.confirmed_at)}`
                      : ""}
                    {p.closed_reason ? ` · ${p.closed_reason}` : ""} ·{" "}
                    <a href={`/backoffice/documents/${p.evidence_document_id}`} className="underline underline-offset-4">
                      RIB
                    </a>
                  </p>
                  {p.status === "proposed" && isAdmin && !p.proposed_by_me ? (
                    <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                      <summary className="cursor-pointer text-sm font-medium">Confirmer (second administrateur)</summary>
                      <ActionForm
                        action={confirmPayoutAccount}
                        submitLabel="Confirmer l'IBAN"
                        pendingLabel="Confirmation…"
                        buttonClassName={buttonClass}
                        className="mt-3 flex flex-col gap-2"
                        testId="confirm-payout-form"
                      >
                        <input type="hidden" name="payout_account_id" value={p.id} readOnly />
                        <input type="hidden" name="client_organization_id" value={id} readOnly />
                        <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                        <label className="flex flex-col gap-1 text-sm">
                          IBAN lu sur le RIB
                          <input name="iban_typed" required autoComplete="off" spellCheck={false} className={`${inputClass} font-mono`} />
                        </label>
                      </ActionForm>
                    </details>
                  ) : null}
                  {p.status === "proposed" ? (
                    <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                      <summary className="cursor-pointer text-sm font-medium">Refuser</summary>
                      <ActionForm
                        action={rejectPayoutAccount}
                        submitLabel="Refuser la proposition"
                        pendingLabel="Enregistrement…"
                        buttonClassName={dangerButtonClass}
                        className="mt-3 flex flex-col gap-2"
                      >
                        <input type="hidden" name="payout_account_id" value={p.id} readOnly />
                        <input type="hidden" name="client_organization_id" value={id} readOnly />
                        <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                        <label className="flex flex-col gap-1 text-sm">
                          Motif
                          <input name="reason" required maxLength={2000} className={inputClass} />
                        </label>
                      </ActionForm>
                    </details>
                  ) : null}
                  {(p.status === "active" || p.status === "returned") && isAdmin ? (
                    <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                      <summary className="cursor-pointer text-sm font-medium">Retirer ce compte</summary>
                      <ActionForm
                        action={retirePayoutAccount}
                        submitLabel="Retirer"
                        pendingLabel="Enregistrement…"
                        buttonClassName={dangerButtonClass}
                        className="mt-3 flex flex-col gap-2"
                      >
                        <input type="hidden" name="payout_account_id" value={p.id} readOnly />
                        <input type="hidden" name="client_organization_id" value={id} readOnly />
                        <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                        <p className="text-sm text-zinc-600 dark:text-zinc-400">Les reversements attendront un nouvel IBAN confirmé.</p>
                        <label className="flex flex-col gap-1 text-sm">
                          Motif
                          <input name="reason" required maxLength={2000} className={inputClass} />
                        </label>
                      </ActionForm>
                    </details>
                  ) : null}
                </li>
              ))}
            </ul>
          )}
          <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
            <summary className="cursor-pointer text-sm font-medium">Proposer un IBAN de reversement</summary>
            {ribs.length === 0 ? (
              <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">Joignez d&apos;abord le RIB du client (« Documents du client »).</p>
            ) : (
              <ActionForm
                action={proposePayoutAccount}
                submitLabel="Proposer l'IBAN"
                pendingLabel="Enregistrement…"
                buttonClassName={buttonClass}
                className="mt-3 flex max-w-xl flex-col gap-3"
                resetOnSuccess
                testId="propose-payout-form"
              >
                <input type="hidden" name="client_organization_id" value={id} readOnly />
                <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                <label className="flex flex-col gap-1 text-sm">
                  RIB
                  <select name="evidence_document_id" className={inputClass}>
                    {ribs.map((d) => (
                      <option key={d.id} value={d.id}>
                        {d.file_name ?? "RIB"} · {frenchDateTime(d.created_at)}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="flex flex-col gap-1 text-sm">
                  IBAN (tel qu&apos;il figure sur le RIB)
                  <input name="iban" required autoComplete="off" spellCheck={false} className={`${inputClass} font-mono`} />
                </label>
                <div className="grid gap-3 sm:grid-cols-2">
                  <label className="flex flex-col gap-1 text-sm">
                    Titulaire (tel qu&apos;il figure sur le RIB)
                    <input name="holder_name" required maxLength={70} className={inputClass} />
                  </label>
                  <label className="flex flex-col gap-1 text-sm">
                    BIC (facultatif)
                    <input name="bic" maxLength={11} autoComplete="off" className={`${inputClass} font-mono`} />
                  </label>
                </div>
                <label className="flex flex-col gap-1 text-sm">
                  Compte de
                  <select name="kind" defaultValue="client" className={inputClass}>
                    <option value="client">Le client</option>
                    <option value="court_appointed">Un mandataire de justice (liquidateur, administrateur)</option>
                  </select>
                </label>
                <input type="hidden" name="currency" value="EUR" readOnly />
              </ActionForm>
            )}
          </details>
        </Section>
      ) : null}

      <Section title="Mandats et conditions financières" testId="mandates">
        {mandates.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun mandat.</p>
        ) : (
          mandates.map((m) => {
            const versions = [...m.mandate_terms].sort((a, b) => a.valid_from.localeCompare(b.valid_from));
            const latest = versions[versions.length - 1];
            return (
              <article key={m.id} className="mb-4 flex flex-col gap-3" data-testid="mandate">
                <header>
                  <p className="font-medium">
                    {m.reference} · signé le {frenchDate(m.signed_on)}
                  </p>
                  <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="insurance-clause">
                    Garantie (R124-3 2°) : {m.insurance_clause_ref ?? "clause non renseignée"}
                  </p>
                </header>
                {isAdmin ? (
                  <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                    <summary className="cursor-pointer text-sm font-medium">Clause de garantie</summary>
                    <ActionForm
                      action={setInsuranceClause}
                      submitLabel="Enregistrer la clause"
                      pendingLabel="Enregistrement…"
                      buttonClassName={buttonClass}
                      className="mt-3 flex flex-col gap-2"
                    >
                      <input type="hidden" name="mandate_id" value={m.id} readOnly />
                      <input type="hidden" name="client_organization_id" value={id} readOnly />
                      <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                      <input type="hidden" name="expected" value={m.insurance_clause_ref ?? ""} readOnly />
                      <label className="flex flex-col gap-1 text-sm">
                        Référence de la clause
                        <input name="clause_ref" required maxLength={200} defaultValue={m.insurance_clause_ref ?? ""} className={inputClass} />
                      </label>
                    </ActionForm>
                  </details>
                ) : null}
                <ol className="flex flex-col gap-3">
                  {versions.map((v) => (
                    <li key={v.id} className="rounded-md bg-zinc-50 p-3 text-sm dark:bg-zinc-900" data-testid="terms-version">
                      <p className="font-medium">
                        Du {frenchDate(v.valid_from)}
                        {v.valid_to ? ` au ${frenchDate(v.valid_to)} (exclu)` : ""}
                        {v.valid_from > today ? " · à venir" : !v.valid_to || v.valid_to > today ? " · en vigueur" : " · terminée"}
                      </p>
                      <p className="text-zinc-600 dark:text-zinc-400">
                        Rémunération (R124-3 3°) : {v.commission_clause_ref ?? "clause non renseignée"} · Reversements (R124-3
                        4°) : {v.remittance_clause_ref ?? "clause non renseignée"}
                        {v.document_id ? (
                          <>
                            {" · "}
                            <a href={`/backoffice/documents/${v.document_id}`} className="underline underline-offset-4">
                              {docName.get(v.document_id) ?? "mandat signé"}
                            </a>
                          </>
                        ) : (
                          " · mandat signé non joint"
                        )}
                      </p>
                      <ul className="mt-2 list-disc pl-5" data-testid="schedule-words">
                        {scheduleInWords(v.commission_schedule, claimLabels).map((l) => (
                          <li key={l}>{l}</li>
                        ))}
                        {termsInWords(v.remittance_terms, v.remittance_max_days).map((l) => (
                          <li key={l}>{l}</li>
                        ))}
                        {!v.commission_schedule ? <li>Barème non renseigné</li> : null}
                        {!v.remittance_terms ? <li>Conditions de reversement non renseignées</li> : null}
                      </ul>
                    </li>
                  ))}
                </ol>
                {isAdmin ? (
                  <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                    <summary className="cursor-pointer text-sm font-medium">Nouvelles conditions financières</summary>
                    {mandateDocs.length === 0 ? (
                      <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
                        Joignez d&apos;abord le mandat signé ou l&apos;avenant (« Documents du client »).
                      </p>
                    ) : (
                      <ActionForm
                        action={setMandateTerms}
                        submitLabel="Enregistrer la version"
                        pendingLabel="Enregistrement…"
                        buttonClassName={buttonClass}
                        className="mt-3 flex max-w-2xl flex-col gap-3"
                        testId="terms-form"
                      >
                        <input type="hidden" name="mandate_id" value={m.id} readOnly />
                        <input type="hidden" name="client_organization_id" value={id} readOnly />
                        <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                        <input type="hidden" name="expected_latest_id" value={latest?.id ?? ""} readOnly />
                        <p className="text-sm text-zinc-600 dark:text-zinc-400">
                          Une version s&apos;applique aux encaissements à partir de sa date, jamais avant : la version en vigueur
                          prend fin ce jour-là.
                        </p>
                        <div className="grid gap-3 sm:grid-cols-2">
                          <label className="flex flex-col gap-1 text-sm">
                            En vigueur à partir du
                            <input type="date" name="valid_from" required min={today} defaultValue={today} className={inputClass} />
                          </label>
                          <label className="flex flex-col gap-1 text-sm">
                            Délai de reversement (jours, 30 au plus)
                            <input
                              name="remittance_max_days"
                              inputMode="numeric"
                              defaultValue={latest?.remittance_max_days ?? 30}
                              className={inputClass}
                            />
                          </label>
                          <label className="flex flex-col gap-1 text-sm">
                            Clause de rémunération
                            <input
                              name="commission_clause_ref"
                              required
                              maxLength={200}
                              defaultValue={latest?.commission_clause_ref ?? ""}
                              placeholder="art. 6 — Rémunération"
                              className={inputClass}
                            />
                          </label>
                          <label className="flex flex-col gap-1 text-sm">
                            Clause de reversement
                            <input
                              name="remittance_clause_ref"
                              required
                              maxLength={200}
                              defaultValue={latest?.remittance_clause_ref ?? ""}
                              placeholder="art. 7 — Reversements"
                              className={inputClass}
                            />
                          </label>
                          <label className="flex flex-col gap-1 text-sm">
                            Fréquence
                            <select
                              name="frequency"
                              defaultValue={(latest?.remittance_terms as { frequency?: string } | null)?.frequency ?? "twice_monthly"}
                              className={inputClass}
                            >
                              <option value="twice_monthly">Deux fois par mois (1er et 16)</option>
                              <option value="weekly">Chaque semaine</option>
                            </select>
                          </label>
                          <label className="flex flex-col gap-1 text-sm">
                            Jour (hebdomadaire)
                            <select
                              name="weekday"
                              defaultValue={String((latest?.remittance_terms as { weekday?: number } | null)?.weekday ?? 2)}
                              className={inputClass}
                            >
                              <option value="1">Lundi</option>
                              <option value="2">Mardi</option>
                              <option value="3">Mercredi</option>
                              <option value="4">Jeudi</option>
                              <option value="5">Vendredi</option>
                            </select>
                          </label>
                          <label className="flex flex-col gap-1 text-sm">
                            Clause de compensation (vide : aucune)
                            <input
                              name="netting_clause"
                              maxLength={200}
                              defaultValue={
                                (latest?.remittance_terms as { netting?: { clause_ref?: string } | null } | null)?.netting?.clause_ref ?? ""
                              }
                              className={inputClass}
                            />
                          </label>
                          <label className="flex flex-col gap-1 text-sm">
                            Clause de reprise des avances (vide : aucune)
                            <input
                              name="clawback_clause"
                              maxLength={200}
                              defaultValue={
                                (latest?.remittance_terms as { clawback?: { clause_ref?: string } | null } | null)?.clawback?.clause_ref ??
                                ""
                              }
                              className={inputClass}
                            />
                          </label>
                          <label className="flex flex-col gap-1 text-sm">
                            Paiement des factures dues (jours, 45 au plus)
                            <input
                              name="invoice_payment_days"
                              inputMode="numeric"
                              defaultValue={
                                (latest?.remittance_terms as { invoice_payment_days?: number } | null)?.invoice_payment_days ?? 30
                              }
                              className={inputClass}
                            />
                          </label>
                          <label className="flex flex-col gap-1 text-sm">
                            Mandat signé ou avenant
                            <select name="document_id" defaultValue={latest?.document_id ?? mandateDocs[0]?.id} className={inputClass}>
                              {mandateDocs.map((d) => (
                                <option key={d.id} value={d.id}>
                                  {d.file_name ?? "mandat"} · {frenchDateTime(d.created_at)}
                                </option>
                              ))}
                            </select>
                          </label>
                        </div>
                        <label className="flex flex-col gap-1 text-sm">
                          Barème de commission (commission-1, JSON : taux en texte, montants en centimes)
                          <textarea
                            name="commission_schedule"
                            rows={14}
                            spellCheck={false}
                            defaultValue={JSON.stringify(latest?.commission_schedule ?? SCHEDULE_TEMPLATE, null, 2)}
                            className={`${inputClass} font-mono text-xs`}
                          />
                        </label>
                      </ActionForm>
                    )}
                  </details>
                ) : null}
              </article>
            );
          })
        )}
      </Section>

      {isMoney ? (
        <Section title="Événements du client" testId="client-events">
          {events.length === 0 ? (
            <p className="text-sm text-zinc-600 dark:text-zinc-400">Aucun événement enregistré.</p>
          ) : (
            <ul className="mb-3 flex flex-col gap-1 text-sm">
              {events.map((e) => (
                <li key={e.id} data-testid="client-event">
                  {frenchDate(e.effective_date)} · {EVENT_KIND[e.kind] ?? e.kind}
                  {e.note ? ` · ${e.note}` : ""} ·{" "}
                  <a href={`/backoffice/documents/${e.evidence_document_id}`} className="underline underline-offset-4">
                    justificatif
                  </a>
                </li>
              ))}
            </ul>
          )}
          {isAdmin ? (
            <details className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
              <summary className="cursor-pointer text-sm font-medium">Enregistrer un événement</summary>
              {evidence.length === 0 ? (
                <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">Joignez d&apos;abord le justificatif (« Documents du client »).</p>
              ) : (
                <ActionForm
                  action={recordClientEvent}
                  submitLabel="Enregistrer l'événement"
                  pendingLabel="Enregistrement…"
                  buttonClassName={buttonClass}
                  className="mt-3 flex max-w-xl flex-col gap-3"
                  resetOnSuccess
                >
                  <input type="hidden" name="client_organization_id" value={id} readOnly />
                  <input type="hidden" name="idempotency_key" value={randomUUID()} readOnly />
                  <label className="flex flex-col gap-1 text-sm">
                    Événement
                    <select name="kind" className={inputClass}>
                      {Object.entries(EVENT_KIND).map(([k, label]) => (
                        <option key={k} value={k}>
                          {label}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label className="flex flex-col gap-1 text-sm">
                    Date d&apos;effet
                    <input type="date" name="effective_date" required max={today} className={inputClass} />
                  </label>
                  <label className="flex flex-col gap-1 text-sm">
                    Justificatif
                    <select name="evidence_document_id" className={inputClass}>
                      {evidence.map((d) => (
                        <option key={d.id} value={d.id}>
                          {d.file_name ?? "justificatif"}
                        </option>
                      ))}
                    </select>
                  </label>
                  {courtAccounts.length > 0 ? (
                    <label className="flex flex-col gap-1 text-sm">
                      Compte du mandataire de justice (facultatif)
                      <select name="payout_account_id" defaultValue="" className={inputClass}>
                        <option value="">—</option>
                        {courtAccounts.map((p) => (
                          <option key={p.id} value={p.id}>
                            {p.holder_name} · {p.iban_masked}
                          </option>
                        ))}
                      </select>
                    </label>
                  ) : null}
                  <label className="flex flex-col gap-1 text-sm">
                    Note (facultative)
                    <input name="note" maxLength={2000} className={inputClass} />
                  </label>
                  <p className="text-sm text-zinc-600 dark:text-zinc-400">
                    Leurs effets sur les reversements viendront avec les reversements (payeur, compensation : question ouverte
                    OQ-41).
                  </p>
                </ActionForm>
              )}
            </details>
          ) : null}
        </Section>
      ) : null}

      <p className="text-sm">
        <Link href="/backoffice/parametres/facturation" className="underline underline-offset-4">
          Identité de facturation du cabinet
        </Link>
      </p>
    </WidePage>
  );
}
