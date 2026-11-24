import Link from "next/link";
import { ClientPaymentSheet } from "@/components/settlements/client-payment-sheet";
import { ClientRefundSheet } from "@/components/settlements/client-refund-sheet";
import { RepaymentRequestSheet, WithdrawRequestSheet } from "@/components/settlements/repayment-request-sheet";
import { Badge, InfoNote, Section } from "@/components/ui";
import { money } from "@/lib/payments/statements";
import { type AdvanceCause, advanceOrigin } from "@/lib/remittance/advances";
import {
  type RepaymentRequestRow,
  owesRequestCandidates,
  requestLetterNote,
  spaceRequestLine,
  withdrawEffect,
} from "@/lib/remittance/requests";
import {
  type ClientCredit,
  type OpenDocuments,
  creditLabel,
  creditOwedText,
  staffCreditGroups,
  writtenOffLine,
} from "@/lib/remittance/settlements";

function frenchDay(iso: string | null): string {
  if (!iso) return "";
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y}`;
}

const ROW = "flex flex-col gap-1 border-b border-zinc-100 py-2 text-sm last:border-0 dark:border-zinc-900";

/**
 * M2c-7c-1 (plan §5.5): « Ce que le client doit au cabinet » — its open invoices, the advances it owes back, the advances
 * written off it may still repay, and, the other way, what the servicer owes it back (credit notes on paid invoices,
 * credits from its payments) with « Enregistrer le remboursement ». Every amount and date is SQL's
 * (public.client_open_documents). Money staff only; « Enregistrer un règlement » records its transfer to the own account.
 * M2c-7c-2 (plan §5.5): « Demander le remboursement » of the advances no claw-back clause recovers (the sheet's total
 * from SQL), « Demandé le » on each requested advance, the client's requests with « Retirer la demande ». (Review round
 * 1, TUI-5) a reminder 30 days after the last request (« Relancer »), as « Avances »; (UI-1) the withdrawal's notice
 * names the requests that still name its advances; (TUI-4) a request withdrawn before its letter was drawn says so.
 */
export function ClientOwes({
  docs,
  servicerId,
  clientName,
  refunded,
  requests = [],
  requested = null,
  withdrawn = null,
  stillRequested = [],
}: {
  docs: OpenDocuments;
  servicerId: string;
  clientName: string;
  refunded: boolean;
  requests?: RepaymentRequestRow[];
  requested?: string | null;
  withdrawn?: string | null;
  stillRequested?: string[];
}) {
  const cur = docs.currency;
  const back = `/backoffice/clients/${docs.client_id}/reversement`;
  // a request not withdrawn that names the advance (the newest first: SQL's order)
  const requestOf = (advanceId: string) =>
    requests.find((q) => q.withdrawn_on === null && q.currency === cur && q.advance_ids.includes(advanceId)) ?? null;
  // what « Demander le remboursement » (or « Relancer », 30 days after the last request) offers — SQL refuses on submit
  // what it may not: in the sheet's preview first
  const offer = owesRequestCandidates(docs.advances, requests, cur, docs.today);
  const candidates = offer.candidates;
  // (review round 1, TUI-4) what is owed back to the client apart from what is held for its procedure
  const credits = staffCreditGroups(docs);
  const creditRow = (c: ClientCredit) => (
    <li key={c.id} className={ROW} data-testid="owes-credit">
      <span className="flex flex-wrap items-center gap-2">
        <span>{creditLabel(c)}</span>
        <span className="font-medium">{creditOwedText(c, cur)}</span>
      </span>
      {docs.own_account ? (
        <ClientRefundSheet
          servicerId={servicerId}
          clientId={docs.client_id}
          documentId={c.id}
          kind="client_credit"
          cause={c.cause}
          title={creditLabel(c)}
          owedMinor={c.open_minor}
          currency={cur}
          today={docs.today}
          earliest={c.received_on}
        />
      ) : null}
    </li>
  );
  const nothing =
    docs.invoices.length + docs.advances.length + docs.written_off.length + docs.refunds_owed.length + docs.credits.length === 0;
  return (
    <Section title="Ce que le client doit au cabinet" testId="client-owes">
      {requested ? (
        <div role="status" aria-live="polite" className="mb-2" data-testid="request-notice">
          <InfoNote>
            Demande {requested} adressée au client : la lettre est déposée dans son espace client ; imprimez-la pour un
            envoi postal.
          </InfoNote>
        </div>
      ) : null}
      {withdrawn ? (
        <div role="status" aria-live="polite" className="mb-2" data-testid="withdraw-notice">
          <InfoNote>{withdrawEffect(withdrawn, stillRequested)}</InfoNote>
        </div>
      ) : null}
      {refunded ? (
        <div role="status" aria-live="polite" className="mb-2" data-testid="client-refund-done">
          <InfoNote>Remboursement enregistré.</InfoNote>
        </div>
      ) : null}
      {docs.procedure ? (
        <div className="mb-2">
          <InfoNote>
            Une procédure collective du client est en cours : une somme reçue pour une créance antérieure à son ouverture
            n&apos;est pas imputée ; elle est inscrite comme à rendre à la procédure (avis de l&apos;avocat, OQ-98).
          </InfoNote>
        </div>
      ) : null}
      {nothing ? <p className="text-sm text-zinc-600 dark:text-zinc-400">Rien d&apos;ouvert entre le client et le cabinet.</p> : null}
      {docs.invoices.length > 0 ? (
        <>
          <h3 className="mt-2 text-sm font-medium">Factures</h3>
          <ul>
            {docs.invoices.map((i) => (
              <li key={i.id} className={ROW} data-testid="owes-invoice">
                <span className="flex flex-wrap items-center gap-2">
                  <Link href={`/backoffice/reversements/factures/${i.id}`} className="font-medium underline underline-offset-4">
                    {i.number}
                  </Link>
                  <span>
                    émise le {frenchDay(i.issue_date)}
                    {i.due_date ? ` · échéance ${frenchDay(i.due_date)}` : ""}
                  </span>
                  <span className="font-medium">reste {money(i.open_minor, cur)}</span>
                  {BigInt(i.pending_vat_minor) > BigInt(0) ? (
                    <span className="text-zinc-600 dark:text-zinc-400">dont TVA {money(i.pending_vat_minor, cur)} exigible au règlement</span>
                  ) : null}
                </span>
                {i.in_flight_run ? <Badge tone="busy">Réglée par le reversement {i.in_flight_run.number} en cours</Badge> : null}
                {i.before_opening ? (
                  <span className="text-zinc-600 dark:text-zinc-400">Créance antérieure à l&apos;ouverture de la procédure du client</span>
                ) : null}
              </li>
            ))}
          </ul>
        </>
      ) : null}
      {docs.advances.length > 0 ? (
        <>
          <h3 className="mt-2 text-sm font-medium">Avances du cabinet</h3>
          <ul>
            {docs.advances.map((a) => (
              <li key={a.id} className={ROW} data-testid="owes-advance">
                <span className="flex flex-wrap items-center gap-2">
                  <span className="font-medium">Avance du {frenchDay(a.born_on)}</span>
                  <span>{advanceOrigin({ cause: a.cause as AdvanceCause, file_ref: null })}</span>
                  {a.mandate_reference ? <span>mandat {a.mandate_reference}</span> : null}
                  <span className="font-medium">reste {money(a.open_minor, cur)}</span>
                </span>
                {a.in_flight_run ? <Badge tone="busy">Reprise par le reversement {a.in_flight_run.number} en cours</Badge> : null}
                {requestOf(a.id) ? (
                  <span className="text-zinc-600 dark:text-zinc-400" data-testid="owes-advance-requested">
                    Demandé le {frenchDay(requestOf(a.id)?.issue_date ?? null)} ({requestOf(a.id)?.number})
                  </span>
                ) : null}
                {a.before_opening ? (
                  <span className="text-zinc-600 dark:text-zinc-400">Créance antérieure à l&apos;ouverture de la procédure du client</span>
                ) : null}
              </li>
            ))}
          </ul>
        </>
      ) : null}
      {candidates.length > 0 ? (
        <div className="mt-2">
          <RepaymentRequestSheet
            clientId={docs.client_id}
            clientName={clientName}
            currency={cur}
            candidates={candidates}
            initial={candidates.map((c) => c.advance_id)}
            label={offer.label ?? undefined}
            back={back}
          />
        </div>
      ) : null}
      {requests.length > 0 ? (
        <>
          <h3 className="mt-2 text-sm font-medium">Demandes de remboursement d&apos;avances</h3>
          <ul>
            {requests.map((q) => (
              <li key={q.request_id} className={ROW} data-testid="owes-request">
                <span className="flex flex-wrap items-center gap-2">
                  <span>{spaceRequestLine(q)}</span>
                  {q.document_id ? (
                    <a
                      href={`/backoffice/reversements/documents/${q.document_id}`}
                      className="font-medium underline underline-offset-4"
                    >
                      Lettre (PDF)
                    </a>
                  ) : (
                    <span className="text-zinc-600 dark:text-zinc-400">{requestLetterNote(q, "staff")}</span>
                  )}
                </span>
                {q.withdrawn_on === null ? <WithdrawRequestSheet requestId={q.request_id} number={q.number} back={back} /> : null}
              </li>
            ))}
          </ul>
        </>
      ) : null}
      {docs.written_off.length > 0 ? (
        <>
          <h3 className="mt-2 text-sm font-medium">Avances passées en perte</h3>
          <ul>
            {docs.written_off.map((w) => (
              <li key={w.id} className={ROW} data-testid="owes-written-off">
                <span>{writtenOffLine(w, cur)}</span>
              </li>
            ))}
          </ul>
        </>
      ) : null}
      {docs.refunds_owed.length > 0 || credits.client.length > 0 ? (
        <h3 className="mt-2 text-sm font-medium">{credits.clientTitle}</h3>
      ) : null}
      {docs.refunds_owed.length > 0 ? (
        <ul>
          {docs.refunds_owed.map((f) => (
            <li key={f.id} className={ROW} data-testid="owes-refund">
              <span className="flex flex-wrap items-center gap-2">
                <Link href={`/backoffice/reversements/factures/${f.id}`} className="font-medium underline underline-offset-4">
                  Avoir {f.number}
                </Link>
                <span>du {frenchDay(f.issue_date)}</span>
                <span className="font-medium">{money(f.owed_minor, cur)} à rembourser</span>
              </span>
              {f.in_flight_run ? (
                <Badge tone="busy">Remboursé avec le reversement {f.in_flight_run.number} en cours</Badge>
              ) : docs.own_account ? (
                <ClientRefundSheet
                  servicerId={servicerId}
                  clientId={docs.client_id}
                  documentId={f.id}
                  kind="credit_note"
                  title={`Avoir ${f.number}`}
                  owedMinor={f.owed_minor}
                  currency={cur}
                  today={docs.today}
                  earliest={f.issue_date}
                />
              ) : null}
            </li>
          ))}
        </ul>
      ) : null}
      {credits.client.length > 0 ? <ul>{credits.client.map(creditRow)}</ul> : null}
      {credits.procedure.length > 0 ? (
        <>
          <h3 className="mt-2 text-sm font-medium">{credits.procedureTitle}</h3>
          <ul>{credits.procedure.map(creditRow)}</ul>
        </>
      ) : null}
      <div className="mt-3 flex flex-col gap-2">
        {!docs.own_account ? (
          <InfoNote>Aucun compte propre n&apos;est enregistré (Paramètres › Facturation).</InfoNote>
        ) : null}
        <ClientPaymentSheet servicerId={servicerId} clientId={docs.client_id} clientName={clientName} docs={docs} />
      </div>
    </Section>
  );
}
