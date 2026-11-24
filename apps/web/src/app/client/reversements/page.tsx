import Link from "next/link";
import { redirect } from "next/navigation";
import { Badge, InfoNote, Section, Stats, WidePage } from "@/components/ui";
import type { SessionClaims } from "@/lib/auth/access";
import { money } from "@/lib/payments/statements";
import { clientSpaceAdvances, parseClientSpaceAdvances } from "@/lib/remittance/advances";
import { clientOfUser } from "@/lib/remittance/client-space";
import { parseClientRepaymentRequests, requestLetterNote, spaceRequestLine } from "@/lib/remittance/requests";
import { clientSpaceCreditSections, parseClientSpaceCredits } from "@/lib/remittance/settlements";
import {
  type RemittanceSummary,
  frenchDay,
  inFlightNotes,
  listPage,
  pageOf,
  returnedRuns,
  cancelledRuns,
  statementRunView,
  unplannedRuns,
} from "@/lib/remittance/documents";
import { createClient } from "@/lib/supabase/server";

const PAGE_SIZE = 100;

/**
 * M2c-5 « Reversements » (client space, design §17.7; C. civ. 1993: the account of what we collected): what is owed to
 * the client today (its running 4670 balance) and how much of it the payout in flight already covers (« ordonné »
 * until the bank's debit, never « payé »), the next scheduled run, and every statement with its PDF and CSV (SHA-256
 * shown), newest first, a page at a time. The client's members with access to the whole client only (OQ-48: a user
 * restricted to some portfolios reads that it is not covered); RLS decides.
 *
 * Review M2c-5: each statement reads its run as it stands (`remittance_run!run_id`, K7) — never the status frozen in
 * the statement's payload, which stays « approved » after a cancellation or the debit; the in-flight gross is worded as
 * part of « À reverser à ce jour » (K2); the list pages (« Plus anciens »). Review M2c-6b-1 (legal-texts#6, K4): a run
 * whose payout came back reads « Virement revenu impayé le … » (the summary's `returned_runs`: the client cannot read
 * the transfer itself) — round 2 (L2): « … : son montant sera reversé par un prochain reversement » until the run that
 * pays it again is booked, then « … : reversé à nouveau par le reversement <numéro> » (`repaid_by`). M2c-6b-2c
 * (plan §7.4; critic L6, critic2 ML-12): the debit's date (`booked_on`), and a cancelled run whose payout the bank
 * executed all the same reads so (`unplanned_runs`), never « Annulé avant la remise de son virement à la banque ».
 */
export default async function ClientRemittancesPage({ searchParams }: PageProps<"/client/reversements">) {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  const claims = (data?.claims ?? null) as SessionClaims | null;
  if (!claims?.sub) redirect("/connexion");
  const back = { href: "/client", label: "Espace client" };
  const { client, restricted } = await clientOfUser(supabase, claims);
  if (!client) {
    return (
      <WidePage title="Reversements" back={back}>
        <InfoNote>Aucun client rattaché à votre compte.</InfoNote>
      </WidePage>
    );
  }
  if (restricted) {
    return (
      <WidePage title="Reversements" back={back}>
        <InfoNote>
          Vos accès ne couvrent pas les relevés de reversement : ils portent sur tous les portefeuilles du client.
        </InfoNote>
      </WidePage>
    );
  }
  const list = listPage((await searchParams).page, PAGE_SIZE);
  const [
    { data: summaryData, error },
    { data: statementRows },
    { data: advancesData },
    { data: creditsData },
    { data: requestsData },
  ] = await Promise.all([
    supabase.rpc("client_remittance_summary", { p_client_organization_id: client.id }),
    supabase
      .from("remittance_statement")
      .select(
        "run_id, number, issue_date, currency, line_count, file_count, pdf_document_id, csv_document_id, csv_sha256, run:remittance_run!run_id(status, gross_minor, net_minor, booked_on)",
      )
      .eq("client_organization_id", client.id)
      .order("issue_date", { ascending: false })
      .order("number", { ascending: false })
      .range(list.from, list.to),
    // M2c-7b (plan §4.3): the servicer's advances still to repay, and how each is recovered
    supabase.rpc("client_space_advances", { p_client_organization_id: client.id }),
    // M2c-7c-1 (plan §5.5): what the servicer owes the client back (a surplus of its payment)
    supabase.rpc("client_space_credits", { p_client_organization_id: client.id }),
    // M2c-7c-2 (plan §5.5): the servicer's repayment requests, each with its letter
    supabase.rpc("client_repayment_requests", { p_client_organization_id: client.id }),
  ]);
  const requests = parseClientRepaymentRequests(requestsData)?.rows ?? [];
  const creditRows = parseClientSpaceCredits(creditsData) ?? { rows: [], total: [] };
  // (review round 1, TUI-1) each section titled by what it holds: « vous doit » only over what is owed to the client
  const creditSections = clientSpaceCreditSections(creditRows);
  const advances = clientSpaceAdvances(parseClientSpaceAdvances(advancesData) ?? { rows: [], total: [] }, requests);
  const summary = (summaryData ?? null) as unknown as RemittanceSummary | null;
  const owed = summary?.owed ?? [];
  const notes = inFlightNotes(summary);
  // review M2c-6b-1 (legal-texts#6, K4): the runs whose payout came back (their run stays booked); round 2 (L2): with
  // the run that paid each again
  const returned = returnedRuns(summary);
  // M2c-6b-2c (critic L6, critic2 ML-12): a cancelled run the bank executed all the same, never « avant la remise »
  const unplanned = unplannedRuns(summary);
  const cancelled = cancelledRuns(summary);
  const statements = pageOf(statementRows, PAGE_SIZE);
  const href = (page: number) => (page > 0 ? `/client/reversements?page=${page}` : "/client/reversements");
  return (
    <WidePage title="Reversements" back={back}>
      <p className="text-sm text-zinc-600 dark:text-zinc-400" data-testid="remittances-client">
        {client.name} · les sommes encaissées pour votre compte et leurs reversements. Chaque reversement a son relevé (PDF)
        et le détail de chaque encaissement (CSV).
      </p>
      {error ? <InfoNote>Les reversements ne peuvent pas être affichés pour l&apos;instant. Réessayez.</InfoNote> : null}
      <Stats
        items={[
          {
            label: "À reverser à ce jour",
            value: owed.length > 0 ? owed.map((o) => money(o.owed_minor, o.currency)).join(" · ") : money("0", "EUR"),
            testId: "owed-today",
          },
          {
            label: "Prochain reversement prévu",
            value: summary?.next_run_day ? `le ${frenchDay(summary.next_run_day)}` : "—",
            testId: "next-run",
          },
        ]}
      />
      {notes.sentences.map((s) => (
        <p key={s} className="text-sm" data-testid="owed-in-flight">
          {s}
        </p>
      ))}
      {advances.heading ? (
        <Section title={advances.heading} testId="client-advances">
          <ul className="flex flex-col gap-1 text-sm">
            {advances.lines.map((l) => (
              <li key={l}>{l}</li>
            ))}
          </ul>
        </Section>
      ) : null}
      {requests.length > 0 ? (
        // M2c-7c-2: « Demande de remboursement d'avances DRA-… du … » and its letter (PDF), « demande retirée le … »
        <Section title="Demandes de remboursement d'avances" testId="client-requests">
          <ul className="flex flex-col gap-2 text-sm">
            {requests.map((q) => (
              <li key={q.request_id} className="flex flex-col gap-1" data-testid="request-row">
                <span>{spaceRequestLine(q)}</span>
                {q.document_id ? (
                  <a
                    href={`/client/reversements/documents/${q.document_id}`}
                    className="font-medium underline underline-offset-4"
                    data-testid="request-pdf"
                  >
                    Lettre (PDF)
                  </a>
                ) : requestLetterNote(q, "client") ? (
                  // (review round 1, TUI-4) none for a request withdrawn before its letter was drawn
                  <span className="text-xs text-zinc-600 dark:text-zinc-400">{requestLetterNote(q, "client")}</span>
                ) : null}
              </li>
            ))}
          </ul>
        </Section>
      ) : null}
      {creditSections.map((s) => (
        <Section key={s.testId} title={s.title} testId={s.testId}>
          <ul className="flex flex-col gap-1 text-sm">
            {s.lines.map((l) => (
              <li key={l.id}>{l.text}</li>
            ))}
          </ul>
          {s.note ? <p className="mt-2 text-xs text-zinc-600 dark:text-zinc-400">{s.note}</p> : null}
        </Section>
      ))}
      <p className="text-xs text-zinc-600 dark:text-zinc-400">
        Un reversement peut intervenir plus tôt : chaque encaissement vous est reversé au plus tard dans le délai de votre
        mandat, et jamais plus d&apos;un mois après sa réception.
      </p>
      {(summary?.in_flight ?? [])
        .filter((r) => !notes.covered.has(r.number))
        .map((r) => (
          <InfoNote key={r.number}>
            Reversement {r.number} : virement de {money(r.net_minor, r.currency)} ordonné
            {r.requested_execution_date ? `, exécution demandée le ${frenchDay(r.requested_execution_date)}` : ""}.
          </InfoNote>
        ))}
      <Section title="Relevés de reversement" testId="statements">
        {statements.rows.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">
            {list.page > 0 ? "Aucun relevé plus ancien." : "Aucun relevé pour l'instant."}
          </p>
        ) : (
          <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
            {statements.rows.map((s) => {
              // K7: the run as it stands — a cancellation or the debit after the statement was drawn shows here; review
              // M2c-6b-1 (K4): and a payout that came back, never « débité » in green — round 2 (L2): and the run that
              // paid it again, once booked
              const run = s.run ?? null;
              const view = statementRunView(
                run,
                returned.get(s.run_id),
                unplanned.get(s.run_id),
                cancelled.get(s.run_id),
              );
              return (
                <li key={s.run_id} className="flex flex-col gap-1 py-3" data-testid="statement-row">
                  <span className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-medium">
                      Relevé {s.number} du {frenchDay(s.issue_date)}
                    </span>
                    {view.net !== null ? (
                      <span className="text-lg font-semibold tabular-nums">{money(view.net, s.currency)}</span>
                    ) : (
                      <span className="text-sm text-zinc-600 dark:text-zinc-400">Aucun virement</span>
                    )}
                  </span>
                  <span className="flex flex-wrap items-center gap-2 text-sm text-zinc-600 dark:text-zinc-400">
                    <Badge tone={view.tone} testId="statement-status">
                      {view.label}
                    </Badge>
                    {s.line_count} encaissement(s) · {s.file_count} dossier(s)
                    {run && run.status !== "cancelled" && run.gross_minor !== null
                      ? ` · brut ${money(String(run.gross_minor), s.currency)}`
                      : ""}
                    {run?.status === "cancelled" ? " · les encaissements attendent un prochain reversement" : ""}
                  </span>
                  <span className="flex flex-wrap gap-4 text-sm">
                    <a
                      href={`/client/reversements/documents/${s.pdf_document_id}`}
                      className="font-medium underline underline-offset-4"
                      data-testid="statement-pdf"
                    >
                      Relevé (PDF)
                    </a>
                    <a
                      href={`/client/reversements/documents/${s.csv_document_id}`}
                      className="font-medium underline underline-offset-4"
                      data-testid="statement-csv"
                    >
                      Détail (CSV)
                    </a>
                  </span>
                  <span className="break-all text-xs text-zinc-500">CSV SHA-256 {s.csv_sha256}</span>
                </li>
              );
            })}
          </ul>
        )}
        {list.page > 0 || statements.more ? (
          <nav className="mt-3 flex justify-between gap-3 text-sm" aria-label="Pages des relevés">
            {list.page > 0 ? (
              <Link href={href(list.page - 1)} className="underline underline-offset-4">
                ← Plus récents
              </Link>
            ) : (
              <span />
            )}
            {statements.more ? (
              <Link href={href(list.page + 1)} className="underline underline-offset-4" data-testid="statements-older">
                Plus anciens →
              </Link>
            ) : null}
          </nav>
        ) : null}
      </Section>
      <Link href="/client/factures" className="text-sm font-medium underline underline-offset-4" data-testid="client-invoices-link">
        Factures et avoirs de commission
      </Link>
    </WidePage>
  );
}
