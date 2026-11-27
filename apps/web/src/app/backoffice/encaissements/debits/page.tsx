import { randomUUID } from "node:crypto";
import Link from "next/link";
import { Badge, InfoNote, Section, WidePage } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { frenchDate } from "@/lib/payments/bank-accounts";
import {
  debitReviewRank,
  debitReviewText,
  clientRelayable,
  clientRelayedPaymentEffect,
  decidedLineKind,
  decisionLabel,
  explainable,
  feeEffect,
  heldReleaseEffect,
  holdsLabelReference,
  labelReferenceDebtorEffect,
  labelReferenceExits,
  labelReferenceTopUpEffect,
  lossEffect,
  offersTopUp,
  ownCreditEffect,
  QUEUE_UNREAD,
  lineKindLabel,
  linkGuarded,
  linkOffers,
  linkPayments,
  linkRefundEffect,
  readsLinkOptions,
  relayable,
  relayedPaymentEffect,
  returnEffect,
} from "@/lib/payments/debits";
import { parseAllocationRemitted, type RemittedEntry, returnRemittedNote } from "@/lib/payments/remitted";
import { money, signedMoney } from "@/lib/payments/statements";
import { offersTransferLineBooking } from "@/lib/payments/transfer-lines";
import {
  BookLine,
  Explain,
  LinkLoss,
  LinkRefund,
  LinkReturn,
  ReleaseOwnCredit,
  ResolveDuplicate,
} from "./debit-actions";
import { type ClientChoice, ClientPaymentLine } from "./client-payment-line";
import { BookTransferLine } from "./transfer-line-sheet";
import { BookTopUpCredit, LabelTopUp } from "./top-up-credit";
import { offersTopUpLink, topUpCreditEffect } from "@/lib/remittance/top-ups";

const PAGE_SIZE = 20;
const TABS: Record<string, string> = {
  "a-classer": "À classer",
  doublons: "Doublons possibles",
  frais: "Frais et autres débits",
  traites: "Traités",
};

type Row = {
  bank_transaction_id: string;
  statement_id: string;
  direction: string;
  kind: string;
  amount_minor: string;
  currency: string;
  booking_date: string;
  age_days: number;
  counterparty_name: string | null;
  counterparty_iban_end: string | null;
  remittance_text: string | null;
  end_to_end_id: string | null;
  original_end_to_end_id: string | null;
  /** M2c-6b-1: a batch line's PmtInfId (one of our files' when it is ours; debit_queue returns it since the review's
   * money-1 fix — on our batch lines the page offers only the refunds debit_link_options lists, linkOffers) */
  payment_info_id?: string | null;
  /** review round 7 (S2): read from a camt.053 entry kept unsplit, how many of its details are ours (offers nothing
   * when any is: holdsOursUnsplit) */
  unsplit_ours?: number | null;
  /** review round 7 (S3): the database's word that a credit names one of our lots of its account (namesOurLot) */
  names_our_lot?: boolean | null;
  return_reason: string | null;
  review_reason: string | null;
  candidates: Candidate[];
  decision: string | null;
  decided_at: string | null;
  decided_payment_id: string | null;
  total: number;
  /** « Doublons possibles »: what the import read the held line as, when the queue tells it (see heldLineKind) */
  held_kind?: string | null;
  /** M2c-6b-2c (critic CSO-4): what « Comptabiliser… » may book the line as, by key (e, b, n, u; null: not offered) —
   * its options are read only when its sheet opens */
  bookable_as?: string | null;
  /** M2c-7e-2 (plan §7.4): a credit held because its CSV label cites one of our transfers — the reference cited and that
   * transfer, by key (labelReferenceText words them) */
  reference_from_label?: string | null;
  label_transfer?: {
    /** M2c-7e-3: the transfer cited, by key (« C'est cet approvisionnement » books that top-up only) */
    transfer_id?: string | null;
    kind?: string | null;
    /** review round 2 (top-text-ignores-status): a top-up's status words whether Collectoo still awaits it */
    status?: string | null;
    amount_minor?: string | null;
    currency?: string | null;
    run_number?: string | null;
  } | null;
};

type Candidate = {
  payment_id?: string;
  refund_request_id?: string;
  amount_minor?: string;
  booking_date?: string;
  payer_name?: string | null;
  left_minor?: string;
  file_reference?: string | null;
  status?: string;
  end_to_end_id?: string;
  refund_status?: string;
  refund_minor?: string;
  /** M2c-6b-2c (critic2 ML-4): a cancelled transfer's run, its status and number (debit_queue's enrichment) */
  transfer_id?: string;
  run_status?: string | null;
  run_number?: string | null;
};
type Options = {
  payments: {
    payment_id: string;
    amount_minor: string;
    booking_date: string;
    payer_name: string | null;
    left_minor: string;
    file_reference: string | null;
  }[];
  refunds: {
    refund_request_id: string;
    amount_minor: string;
    end_to_end_id: string;
    status: string;
    payee_name: string;
  }[];
  /** review 6b-2c round 3: on a debit, link_debit's answer for a payment's return (its code; null: it takes it) */
  return_guard?: string | null;
};

/**
 * M2b-6 « Débits et retours » (design §12): what leaves the client-funds account, phone-first. Lines the debit job
 * could not link (a payment's return, our refund, a refund come back), with what it found and the payments ops may
 * choose; CSV lines held as suspected duplicates; fees and other debits (not booked in M2b: explained gaps, founder
 * #20); lines decided. Every action is a SQL command that checks again what this page showed. Admins and ops managers.
 * M2c-6b-2c (plan §7.3): « Comptabiliser… » on our transfer lines the import could not book (the debit of a payout, a
 * lot, a transfer outside any run, a sweep to our own account, a transfer come back, an entry kept unsplit).
 */
export default async function DebitsPage({
  searchParams,
}: PageProps<"/backoffice/encaissements/debits">) {
  const query = await searchParams;
  const tab =
    typeof query.onglet === "string" && query.onglet in TABS
      ? query.onglet
      : "a-classer";
  const page = Math.max(
    1,
    Number.parseInt(typeof query.page === "string" ? query.page : "1", 10) || 1,
  );
  const { supabase, claims } = await staffSession();
  const back = {
    href: "/backoffice/encaissements",
    label: "Relevés bancaires",
  };
  const { data: memberships } = await supabase
    .from("membership")
    .select("role, organization:organization_id(kind)")
    .eq("user_id", claims.sub ?? "");
  const staff = (memberships ?? []).find(
    (m) => m.organization?.kind === "servicer",
  );
  if (!(staff?.role === "admin" || staff?.role === "ops_manager")) {
    return (
      <WidePage title="Débits et retours" back={back}>
        <InfoNote>
          Les lignes bancaires sont réservées aux administrateurs et aux
          responsables des opérations.
        </InfoNote>
      </WidePage>
    );
  }
  // M2c-6b-3a review round 1 (pages-texts-4): the flag the refund link's refusal is worded by
  const { data: cancellationOn } = await supabase.rpc("cancellation_after_download");
  const cancellationAfterDownload = cancellationOn === true;
  const { data, error: queueError } = await supabase.rpc("debit_queue", {
    p_tab: tab,
    p_offset: (page - 1) * PAGE_SIZE,
    p_limit: PAGE_SIZE,
  });
  const rows = (data ?? []) as unknown as Row[];
  const total = rows[0]?.total ?? 0;
  // review 6b-2c (cs-1): a queue the database could not read (its time limit) is said so, never « Aucune ligne » (0)
  const unread = Boolean(queueError);
  // what ops may link a line to when the job found nothing it could link (bounded: one keyed read per line shown that
  // offers links; never our own transfers and credits, nor our RMT/SWP lines — review round 2, L4)
  const options = new Map<string, Options>();
  if (tab === "a-classer") {
    const reads = await Promise.all(
      rows.map((r) =>
        readsLinkOptions(r)
          ? supabase.rpc("debit_link_options", {
              p_bank_transaction_id: r.bank_transaction_id,
            })
          : Promise.resolve({ data: null }),
      ),
    );
    rows.forEach((r, i) =>
      options.set(
        r.bank_transaction_id,
        (reads[i].data ?? { payments: [], refunds: [] }) as unknown as Options,
      ),
    );
  }
  // M2c-7a (plan §3.7): of the payments a return may be linked to, what was already remitted to the client (one keyed
  // read per payment offered; the return's sheet says the advance the servicer then makes)
  const remitted = new Map<string, RemittedEntry[]>();
  if (tab === "a-classer") {
    const ids = [
      ...new Set(
        rows.flatMap((r) => [
          ...r.candidates.map((c) => c.payment_id).filter((x): x is string => typeof x === "string"),
          ...(options.get(r.bank_transaction_id)?.payments ?? []).map((p) => p.payment_id),
        ]),
      ),
    ];
    const reads = await Promise.all(ids.map((id) => supabase.rpc("allocation_remitted", { p_payment_id: id })));
    ids.forEach((id, i) => remitted.set(id, parseAllocationRemitted(reads[i].data) ?? []));
  }
  // M2c-7e-3 (plan §7.4 « Règlement du client »): the servicer's clients ops may name as the one repaying, read only
  // when a line of the page cites our reference
  let clients: ClientChoice[] = [];
  if (tab === "a-classer" && rows.some(holdsLabelReference)) {
    const { data: orgs } = await supabase
      .from("organization")
      .select("id, legal_name")
      .eq("kind", "creditor_client")
      .order("legal_name")
      .limit(500);
    clients = (orgs ?? []).map((o) => ({ id: o.id, name: o.legal_name }));
  }
  const href = (t: string, p = 1) =>
    `/backoffice/encaissements/debits?onglet=${t}${p > 1 ? `&page=${p}` : ""}`;

  return (
    <WidePage title="Débits et retours" back={back}>
      <InfoNote>
        Un retour de la banque annule les imputations et reversements du
        paiement à la date du retour (notification enregistrée pour le client de
        son dossier) ; un remboursement n&apos;est comptabilisé qu&apos;une fois
        son débit sur le relevé. Les frais bancaires du compte de fonds de tiers
        sont à la charge du cabinet : ceux que la banque code comme tels sont
        comptabilisés automatiquement, les autres avec « Frais bancaires ». Un
        crédit venant du compte propre n&apos;est jamais pris automatiquement
        pour le paiement d&apos;un débiteur : c&apos;est un approvisionnement du
        cabinet, ou le paiement d&apos;un débiteur reçu par le cabinet et relayé
        sur le compte dédié, qui devient alors un paiement à affecter («
        Paiement d&apos;un débiteur relayé par le cabinet »). De même, un crédit
        venant du compte de reversement d&apos;un client règle une facture du
        cabinet, ou relaie le paiement d&apos;un débiteur reçu par le client («
        Paiement d&apos;un débiteur relayé par le client »).
      </InfoNote>
      <nav className="flex flex-wrap gap-2 text-sm" aria-label="Onglets">
        {Object.entries(TABS).map(([key, label]) => (
          <Link
            key={key}
            href={href(key)}
            aria-current={key === tab ? "page" : undefined}
            className={`rounded-full border px-3 py-1 ${
              key === tab
                ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                : "border-zinc-300 dark:border-zinc-700"
            }`}
          >
            {label}
            {key === tab && !unread ? ` (${total})` : ""}
          </Link>
        ))}
      </nav>

      <Section title={TABS[tab]} testId="debit-list">
        {unread ? (
          <p className="text-sm text-amber-900 dark:text-amber-200" data-testid="debit-list-unread">
            {QUEUE_UNREAD}
          </p>
        ) : rows.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">
            Aucune ligne.
          </p>
        ) : (
          <ul className="flex flex-col divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows.map((r) => (
              <li
                key={r.bank_transaction_id}
                id={`ligne-${r.bank_transaction_id}`}
                className="flex flex-col gap-2 py-3"
                data-testid="debit-row"
              >
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <span className="flex flex-wrap items-center gap-2">
                    <Badge tone="neutral">
                      {tab === "doublons"
                        ? lineKindLabel("suspected_duplicate", r.direction)
                        : lineKindLabel(r.kind, r.direction)}
                    </Badge>
                    {tab !== "traites" ? (
                      <Badge tone={r.age_days >= 3 ? "action" : "neutral"}>
                        J+{r.age_days}
                      </Badge>
                    ) : null}
                    {r.decision ? (
                      <Badge tone="ok">
                        {/* review M2c-7e-3 round 1 (TUI-2): a released copy by the kind it was released as */}
                        {decisionLabel(r.decision, decidedLineKind(r))}
                      </Badge>
                    ) : null}
                  </span>
                  <span
                    className={`font-medium tabular-nums ${r.direction === "debit" ? "text-red-800 dark:text-red-300" : ""}`}
                    data-testid="debit-amount"
                  >
                    {signedMoney(r.direction, r.amount_minor, r.currency)}
                  </span>
                </div>
                <p className="text-sm">
                  {frenchDate(r.booking_date)} ·{" "}
                  {r.counterparty_name ?? "Contrepartie non indiquée"}
                  {r.counterparty_iban_end
                    ? ` · IBAN …${r.counterparty_iban_end}`
                    : ""}
                </p>
                {r.remittance_text ? (
                  <p className="text-sm break-words text-zinc-600 dark:text-zinc-400">
                    {r.remittance_text}
                  </p>
                ) : null}
                <p className="text-xs text-zinc-600 dark:text-zinc-400">
                  <span className="font-mono break-all">
                    {r.original_end_to_end_id
                      ? `Réf. d'origine ${r.original_end_to_end_id}`
                      : r.end_to_end_id
                        ? `Réf. ${r.end_to_end_id}`
                        : "Sans référence"}
                    {r.return_reason ? ` · motif ${r.return_reason}` : ""}
                  </span>{" "}
                  ·{" "}
                  <Link
                    href={`/backoffice/encaissements/releves/${r.statement_id}`}
                    className="whitespace-nowrap underline underline-offset-4"
                  >
                    voir le relevé
                  </Link>
                </p>
                {debitReviewText(r, options.get(r.bank_transaction_id)) !== null ? (
                  <p
                    className="text-sm text-amber-900 dark:text-amber-200"
                    data-testid="debit-review"
                  >
                    {debitReviewRank(r.review_reason) === 0 ? (
                      <Badge tone="error" testId="debit-review-p0">
                        Prioritaire
                      </Badge>
                    ) : null}{" "}
                    {/* review round 3 (M1): on our transfer coming back unflagged, what it is in place of the job's
                        top-up or client-credit review */}
                    {debitReviewText(r, options.get(r.bank_transaction_id))}
                  </p>
                ) : null}
                {tab === "a-classer" ? (
                  <LineActions
                    row={r}
                    options={options.get(r.bank_transaction_id)}
                    cancellationAfterDownload={cancellationAfterDownload}
                    remitted={remitted}
                    clients={clients}
                  />
                ) : null}
                {tab === "frais" && r.direction === "debit" ? (
                  <div className="flex flex-col gap-2">
                    <BookLine
                      lineId={r.bank_transaction_id}
                      kind="fee"
                      label="Frais bancaires"
                      effect={feeEffect(money(r.amount_minor, r.currency))}
                      offersBooking={offersTransferLineBooking(r)}
                      idempotencyKey={randomUUID()}
                    />
                    <Explain
                      lineId={r.bank_transaction_id}
                      offersBooking={offersTransferLineBooking(r)}
                      idempotencyKey={randomUUID()}
                    />
                  </div>
                ) : null}
                {tab === "doublons" ? (
                  <ResolveDuplicate
                    lineId={r.bank_transaction_id}
                    // review M2c-7e-3 round 1 (MB-1) and round 2 (liberer-top-up-exit-not-open): what the import read
                    // the copy as (heldLineKind) and, citing our reference, the kind and the status of that transfer
                    releaseEffect={heldReleaseEffect(r)}
                    idempotencyKey={randomUUID()}
                  />
                ) : null}
                {tab === "traites" && r.decided_payment_id ? (
                  <Link
                    href={`/backoffice/encaissements/paiements/${r.decided_payment_id}`}
                    className="text-sm underline underline-offset-4"
                  >
                    Voir le paiement
                  </Link>
                ) : null}
              </li>
            ))}
          </ul>
        )}
        {total > PAGE_SIZE ? (
          <nav
            className="mt-3 flex items-center justify-between gap-3 text-sm"
            aria-label="Pages"
          >
            {page > 1 ? (
              <Link href={href(tab, page - 1)}>← Précédentes</Link>
            ) : (
              <span />
            )}
            <span className="text-zinc-600 dark:text-zinc-400">
              {(page - 1) * PAGE_SIZE + 1}–{Math.min(page * PAGE_SIZE, total)}{" "}
              sur {total}
            </span>
            {page * PAGE_SIZE < total ? (
              <Link href={href(tab, page + 1)}>Suivantes →</Link>
            ) : (
              <span />
            )}
          </nav>
        ) : null}
        {tab === "frais" ? (
          <p className="mt-3 text-xs text-zinc-600 dark:text-zinc-400">
            Les frais de la banque sont à la charge du cabinet :
            comptabilisez-les ici, ou demandez à la banque de les imputer sur le
            compte propre. Un débit du montant d&apos;un remboursement demandé
            sur ce compte peut être ce remboursement, exécuté sans sa référence
            RFD : il est aussi listé dans « À classer », où le lier.
          </p>
        ) : null}
      </Section>
    </WidePage>
  );
}

/**
 * M2c-7e-3 (plan §7.3, §7.4): the exits of a credit held because its label cites one of our transfers, each through its
 * command and its re-checks (labelReferenceExits): (a) « Oui, c'est son retour » (its payout or sweep, the transfer-line
 * sheet's class L), (b) « Règlement du client », (c) « Paiement d'un débiteur », and « C'est cet approvisionnement »
 * (founder Q15's added question, default a — still open).
 */
function LabelReferenceActions({ row, clients }: { row: Row; clients: ClientChoice[] }) {
  const exits = labelReferenceExits(row);
  const amount = money(row.amount_minor, row.currency);
  const top = row.label_transfer;
  return (
    <div className="flex flex-col gap-2" data-testid="label-reference-exits">
      {exits.includes("return") ? (
        <BookTransferLine lineId={row.bank_transaction_id} currency={row.currency} idempotencyKey={randomUUID()} labelReference />
      ) : null}
      {exits.includes("client") ? <ClientPaymentLine lineId={row.bank_transaction_id} clients={clients} /> : null}
      {exits.includes("debtor") ? (
        <ReleaseOwnCredit
          by="label_reference"
          lineId={row.bank_transaction_id}
          effect={labelReferenceDebtorEffect({ amount, dateFr: frenchDate(row.booking_date) })}
          idempotencyKey={randomUUID()}
        />
      ) : null}
      {exits.includes("top_up") && top?.transfer_id ? (
        <LabelTopUp
          lineId={row.bank_transaction_id}
          transferId={top.transfer_id}
          effect={labelReferenceTopUpEffect({ amount, reference: row.reference_from_label ?? "" })}
          idempotencyKey={randomUUID()}
        />
      ) : null}
    </div>
  );
}

/** One line's actions: the payments and refunds the job found, those of the same amount on the account, explain. */
function LineActions({
  row,
  options,
  cancellationAfterDownload = false,
  remitted = new Map(),
  clients = [],
}: {
  row: Row;
  options: Options | undefined;
  cancellationAfterDownload?: boolean;
  /** M2c-7a: per payment, its entries already remitted to the client */
  remitted?: Map<string, RemittedEntry[]>;
  /** M2c-7e-3: the servicer's clients (« Client qui rembourse ») */
  clients?: ClientChoice[];
}) {
  // M2c-7e-2 (plan §7.4): a credit held because its label cites one of our transfers — every link is refused
  // (label_reference_line); M2c-7e-3: it takes only its exits
  if (holdsLabelReference(row)) return <LabelReferenceActions row={row} clients={clients} />;
  const cur = row.currency;
  // the job's named payments, then those debit_link_options listed (one list with the queue's text: linkPayments)
  const payments = linkPayments(row.candidates, options?.payments);
  // review M2c-1, M2c-6b-1 (money-1) and round 2 (L4): what the line may be linked to — on our payouts' and sweeps'
  // lines exactly what debit_link_options lists there (our batch line: its PmtInf's refunds handed out; RMT/SWP lines
  // and their returns: nothing), never « Perte »; M2c-1 (OQ-34): « Perte » on a return naming a payment of which less
  // is left than it takes back
  const {
    returns: returnable,
    losses: beyond,
    refunds,
  } = linkOffers(row, payments, options?.refunds ?? [], options?.return_guard);
  return (
    <div className="flex flex-col gap-2">
      {/* M2c-6b-2c (plan §7.3; critic CSO-4): our transfer lines booked from the statement, the options read on open */}
      {offersTransferLineBooking(row) ? (
        <BookTransferLine
          lineId={row.bank_transaction_id}
          currency={cur}
          idempotencyKey={randomUUID()}
        />
      ) : null}
      {/* review round 3 (M1, M2): neither the top-up nor a relay on a credit carrying our RMT/SWP id (our transfer
          coming back, isOurTransferLine): the database refuses both (own_transfer_line) */}
      {offersTopUp(row) ? (
        <BookLine
          lineId={row.bank_transaction_id}
          kind="own_credit"
          label="Approvisionnement par le compte propre"
          effect={ownCreditEffect(money(row.amount_minor, cur))}
          idempotencyKey={randomUUID()}
        />
      ) : null}
      {/* M2c-7e-1 ([check 1] gap 12): the credit of a top-up whose TOP reference the bank dropped */}
      {offersTopUpLink(offersTopUp(row), row.end_to_end_id) ? (
        <BookTopUpCredit
          lineId={row.bank_transaction_id}
          effect={topUpCreditEffect(money(row.amount_minor, cur))}
          idempotencyKey={randomUUID()}
        />
      ) : null}
      {relayable(row) ? (
        <ReleaseOwnCredit
          lineId={row.bank_transaction_id}
          effect={relayedPaymentEffect({
            amount: money(row.amount_minor, cur),
            dateFr: frenchDate(row.booking_date),
          })}
          idempotencyKey={randomUUID()}
        />
      ) : null}
      {/* M2c-7c-1 (plan §5.5): the client paying the servicer on the dedicated account, beside its relayed payment */}
      {clientRelayable(row) ? <ClientPaymentLine lineId={row.bank_transaction_id} /> : null}
      {clientRelayable(row) ? (
        <ReleaseOwnCredit
          by="client"
          lineId={row.bank_transaction_id}
          effect={clientRelayedPaymentEffect({
            amount: money(row.amount_minor, cur),
            dateFr: frenchDate(row.booking_date),
          })}
          idempotencyKey={randomUUID()}
        />
      ) : null}
      {beyond.map((p) => (
        <LinkLoss
          key={p.payment_id}
          lineId={row.bank_transaction_id}
          paymentId={p.payment_id}
          leftMinor={p.left_minor}
          label={`Retour au-delà du paiement de ${money(p.amount_minor, cur)} du ${frenchDate(p.booking_date)} (perte du cabinet)`}
          effect={lossEffect({
            amount: money(row.amount_minor, cur),
            left: money(p.left_minor, cur),
            excess: money(
              (BigInt(row.amount_minor) - BigInt(p.left_minor)).toString(),
              cur,
            ),
            dateFr: frenchDate(row.booking_date),
            noneLeft: BigInt(p.left_minor) === BigInt(0),
          })}
          idempotencyKey={randomUUID()}
        />
      ))}
      {returnable.map((p) => {
        const full = BigInt(p.left_minor) === BigInt(row.amount_minor);
        return (
          <LinkReturn
            key={p.payment_id}
            lineId={row.bank_transaction_id}
            paymentId={p.payment_id}
            leftMinor={p.left_minor}
            primary={p.named === true}
            label={`Retour du paiement de ${money(p.amount_minor, cur)} du ${frenchDate(p.booking_date)}${p.file_reference ? ` · ${p.file_reference}` : ""}${full ? "" : " (partiel)"}`}
            effect={[
              returnEffect({
                amount: money(row.amount_minor, cur),
                left: money(
                  (BigInt(p.left_minor) - BigInt(row.amount_minor)).toString(),
                  cur,
                ),
                full,
                dateFr: frenchDate(row.booking_date),
                hasFile: Boolean(p.file_reference),
              }),
              returnRemittedNote(remitted.get(p.payment_id) ?? [], cur),
            ]
              .filter((x): x is string => x !== null)
              .join(" ")}
            idempotencyKey={randomUUID()}
          />
        );
      })}
      {refunds.map((q) => (
        <LinkRefund
          key={q.refund_request_id}
          lineId={row.bank_transaction_id}
          refundId={q.refund_request_id}
          kind={row.direction === "debit" ? "refund" : "refund_returned"}
          cancellationAfterDownload={cancellationAfterDownload}
          label={`${row.direction === "debit" ? "Remboursement" : "Remboursement revenu"} ${q.end_to_end_id} · ${money(q.amount_minor, cur)}`}
          effect={linkRefundEffect({
            direction: row.direction,
            lineRef: row.end_to_end_id,
            refundRef: q.end_to_end_id,
            payee: q.payee_name,
          })}
          idempotencyKey={randomUUID()}
        />
      ))}
      {/* M2c-6b-2c (plan §4.1): never on a debit « Comptabiliser… » books (link_debit refuses it) */}
      {!linkGuarded(row) &&
      explainable({
        direction: row.direction,
        kind: row.kind,
        namesPayment: payments.some((p) => p.named === true),
        endToEndId: row.end_to_end_id,
        originalEndToEndId: row.original_end_to_end_id,
        paymentInfoId: row.payment_info_id ?? null,
        namesOurLot: row.names_our_lot ?? false,
        unsplitOurs: row.unsplit_ours ?? null,
      }) ? (
        <Explain
          lineId={row.bank_transaction_id}
          offersBooking={offersTransferLineBooking(row)}
          idempotencyKey={randomUUID()}
        />
      ) : null}
    </div>
  );
}
