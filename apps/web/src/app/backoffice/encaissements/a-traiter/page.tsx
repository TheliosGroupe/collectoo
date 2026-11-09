import { randomUUID } from "node:crypto";
import Link from "next/link";
import { AutoRefresh } from "@/components/auto-refresh";
import { Badge, InfoNote, WidePage, buttonClass, inputClass } from "@/components/ui";
import { staffSession } from "@/lib/auth/staff";
import { frenchDate } from "@/lib/payments/bank-accounts";
import {
  METHOD_LABEL,
  QUEUE_PAGE_SIZE,
  type QueueAccount,
  REASON_FILTERS,
  type Signals,
  ageBadge,
  citedReferences,
  fileLabel,
  formatRf,
  highlight,
  minorToEuros,
  queueHref,
  queueQuery,
  reviewReason,
  signalText,
} from "@/lib/payments/matching";
import { money } from "@/lib/payments/statements";
import { AcceptSuggestion, BulkAccept, ChooseFile, SearchAndAssign, Unassign } from "./queue-actions";

const NO_SUGGESTION_HELP =
  "Aucune règle ne désigne un dossier : cherchez-le par sa référence, un numéro de facture, la référence RF ou le nom du débiteur.";

type Row = {
  payment_id: string;
  amount_minor: string;
  currency: string;
  booking_date: string;
  age_days: number;
  payer_name: string | null;
  payer_iban_end: string | null;
  remittance_text: string | null;
  creditor_reference: string | null;
  status: string;
  review_reason: string | null;
  match_method: string | null;
  account_id: string | null;
  candidate_account_id: string | null;
  total: number;
};
type Candidate = { payment_id: string; rank: number; account_id: string; rule: string; acceptable: boolean; signals: Signals };
type Decision = { payment_id: string; action: string; rule: string | null; evidence: Signals & { designation?: string[] } };

/** A bigint filter for PostgREST, as text (exact; the generated type says number). */
function bigintParam(v: bigint | null): number | undefined {
  return v === null ? undefined : (v.toString() as unknown as number);
}

/**
 * M2b-3 « Paiements à traiter » (design §12.2): the exception queue, phone-first. One card per payment,
 * oldest first, with its age since the booking date, the payer, the remittance text with the references
 * the rules read, the reason and the best suggestion as one button. Tab « Rapprochés »: the payments
 * matched and ready for allocation, which ops can take off a wrong file. Admins and ops managers only
 * (third-party payer data, decision #18); every action is a command checked in SQL.
 */
export default async function QueuePage({ searchParams }: PageProps<"/backoffice/encaissements/a-traiter">) {
  const q = queueQuery(await searchParams);
  const { supabase, claims } = await staffSession();
  const [{ data: memberships }, { data: orgs }] = await Promise.all([
    supabase.from("membership").select("role, organization:organization_id(kind)").eq("user_id", claims.sub ?? ""),
    supabase.from("organization").select("id, legal_name, kind").order("legal_name"),
  ]);
  const staff = (memberships ?? []).find((m) => m.organization?.kind === "servicer");
  const canWork = staff?.role === "admin" || staff?.role === "ops_manager";
  const back = { href: "/backoffice/encaissements", label: "Relevés bancaires" };
  if (!canWork) {
    return (
      <WidePage title="Paiements à traiter" back={back}>
        <InfoNote>Les paiements sont réservés aux administrateurs et aux responsables des opérations.</InfoNote>
      </WidePage>
    );
  }
  const clients = (orgs ?? []).filter((o) => o.kind !== "servicer");

  const { data } = await supabase.rpc("payment_queue", {
    p_tab: q.onglet,
    p_reason: q.motif ?? undefined,
    p_client: q.client ?? undefined,
    p_min_minor: bigintParam(q.min),
    p_max_minor: bigintParam(q.max),
    p_min_days: q.age ?? undefined,
    p_offset: (q.page - 1) * QUEUE_PAGE_SIZE,
    p_limit: QUEUE_PAGE_SIZE,
  });
  const rows = (data ?? []) as Row[];
  const total = rows[0]?.total ?? 0;
  const ids = rows.map((r) => r.payment_id);
  const [{ data: cands }, { data: decisions }] = await Promise.all([
    ids.length
      ? supabase
          .from("payment_match_candidate")
          .select("payment_id, rank, account_id, rule, acceptable, signals")
          .in("payment_id", ids)
          .order("rank")
      : Promise.resolve({ data: [] }),
    ids.length
      ? supabase
          .from("payment_match")
          .select("payment_id, action, rule, evidence")
          .in("payment_id", ids)
          .eq("action", "assign")
          .order("decided_at", { ascending: false })
      : Promise.resolve({ data: [] }),
  ]);
  const candidates = (cands ?? []) as unknown as Candidate[];
  const lastDecision = new Map<string, Decision>();
  for (const d of (decisions ?? []) as unknown as Decision[]) if (!lastDecision.has(d.payment_id)) lastDecision.set(d.payment_id, d);
  const fileIds = [
    ...new Set([
      ...rows.flatMap((r) => [r.account_id, r.candidate_account_id]).filter((x): x is string => !!x),
      ...candidates.map((c) => c.account_id),
    ]),
  ];
  const { data: fileRows } = fileIds.length
    ? await supabase.rpc("match_queue_accounts", { p_account_ids: fileIds })
    : { data: [] };
  const files = new Map((fileRows ?? []).map((f) => [f.account_id, f as QueueAccount]));
  const acceptable = rows.filter((r) => candidates.some((c) => c.payment_id === r.payment_id && c.acceptable)).length;
  const waiting = rows.some((r) => r.status === "unmatched" && r.review_reason === null);
  const filtered = q.motif !== null || q.client !== null || q.min !== null || q.max !== null || q.age !== null;

  return (
    <WidePage title="Paiements à traiter" back={back}>
      <AutoRefresh active={waiting} abandonable={false} everyMs={3000} maxMs={5 * 60_000} />
      <nav className="flex gap-2 text-sm" aria-label="Onglets" data-testid="queue-tabs">
        {(
          [
            ["a-traiter", "À traiter"],
            ["rapproches", "Rapprochés"],
          ] as const
        ).map(([key, label]) => (
          <Link
            key={key}
            href={queueHref(q, { onglet: key, motif: null, page: 1 })}
            aria-current={q.onglet === key ? "page" : undefined}
            className={`rounded-full border px-3 py-1 ${
              q.onglet === key
                ? "border-zinc-900 bg-zinc-900 text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900"
                : "border-zinc-300 dark:border-zinc-700"
            }`}
          >
            {label}
            {q.onglet === key ? ` (${total})` : ""}
          </Link>
        ))}
      </nav>
      <InfoNote>
        {q.onglet === "a-traiter"
          ? "Les règles de rapprochement (référence RF, numéro de facture confirmé, IBAN connu) affectent seules les paiements sûrs ; les autres attendent ici une décision. Un nom et un montant ne sont jamais qu'une suggestion."
          : "Paiements rattachés à un dossier, prêts pour l'imputation. Un paiement affecté au mauvais dossier se désaffecte ici tant que rien n'est imputé."}
      </InfoNote>

      <details open={filtered} className="rounded-lg border border-zinc-200 p-3 dark:border-zinc-800" data-testid="queue-filter-panel">
        <summary className="cursor-pointer text-sm font-medium">Filtres{filtered ? " (actifs)" : ""}</summary>
      <form method="get" action="/backoffice/encaissements/a-traiter" className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-6" aria-label="Filtrer les paiements" data-testid="queue-filters">
        {q.onglet === "rapproches" ? <input type="hidden" name="onglet" value="rapproches" /> : null}
        {q.onglet === "a-traiter" ? (
          <label className="col-span-2 flex flex-col gap-1 text-sm">
            Motif
            <select name="motif" defaultValue={q.motif ?? ""} className={inputClass}>
              <option value="">Tous</option>
              {REASON_FILTERS.map((r) => (
                <option key={r.value} value={r.value}>
                  {r.label}
                </option>
              ))}
            </select>
          </label>
        ) : null}
        <label className="col-span-2 flex flex-col gap-1 text-sm">
          Client
          <select name="client" defaultValue={q.client ?? ""} className={inputClass}>
            <option value="">Tous</option>
            {clients.map((c) => (
              <option key={c.id} value={c.id}>
                {c.legal_name}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Montant min. (€)
          <input name="min" inputMode="decimal" defaultValue={q.min === null ? "" : minorToEuros(q.min)} className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Montant max. (€)
          <input name="max" inputMode="decimal" defaultValue={q.max === null ? "" : minorToEuros(q.max)} className={inputClass} />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          Âge min. (jours)
          <input name="age" inputMode="numeric" defaultValue={q.age ?? ""} className={inputClass} />
        </label>
        <div className="col-span-2 flex items-end gap-2 sm:col-span-1">
          <button type="submit" className={buttonClass}>
            Filtrer
          </button>
        </div>
      </form>
      </details>

      {q.onglet === "a-traiter" && acceptable > 1 ? <BulkAccept idempotencyKey={randomUUID()} count={acceptable} /> : null}

      {rows.length === 0 ? (
        <InfoNote>
          {filtered
            ? "Aucun paiement ne correspond à ces filtres."
            : q.onglet === "a-traiter"
              ? "Aucun paiement à traiter : tous les encaissements sont rattachés à un dossier."
              : "Aucun paiement rapproché en attente d'imputation."}
        </InfoNote>
      ) : (
        <ul className="flex flex-col gap-4" data-testid="queue-list">
          {rows.map((r) => (
            <PaymentCard
              key={r.payment_id}
              row={r}
              candidates={candidates.filter((c) => c.payment_id === r.payment_id)}
              decision={lastDecision.get(r.payment_id) ?? null}
              files={files}
            />
          ))}
        </ul>
      )}

      {total > QUEUE_PAGE_SIZE ? (
        <nav className="flex items-center justify-between gap-3 text-sm" aria-label="Pages">
          {q.page > 1 ? <Link href={queueHref(q, { page: q.page - 1 })}>← Précédents</Link> : <span />}
          <span className="text-zinc-600 dark:text-zinc-400">
            {(q.page - 1) * QUEUE_PAGE_SIZE + 1}–{Math.min(q.page * QUEUE_PAGE_SIZE, total)} sur {total}
          </span>
          {q.page * QUEUE_PAGE_SIZE < total ? <Link href={queueHref(q, { page: q.page + 1 })}>Suivants →</Link> : <span />}
        </nav>
      ) : null}
    </WidePage>
  );
}

function PaymentCard({
  row: r,
  candidates,
  decision,
  files,
}: {
  row: Row;
  candidates: Candidate[];
  decision: Decision | null;
  files: Map<string, QueueAccount>;
}) {
  const amount = money(r.amount_minor, r.currency);
  const reason = reviewReason(r.status === "matched" && r.review_reason === null ? "ready" : r.review_reason);
  const age = ageBadge(r.age_days);
  const file = r.account_id ? files.get(r.account_id) : undefined;
  const waitingFor = r.review_reason === "account_not_confirmed" && r.candidate_account_id ? files.get(r.candidate_account_id) : undefined;
  const refs = [
    ...citedReferences(candidates.map((c) => c.signals)),
    ...citedReferences(decision ? [decision.evidence] : []),
    ...(decision?.evidence.designation ?? []),
  ];
  const top = candidates[0];
  const topFile = top?.acceptable ? files.get(top.account_id) : undefined;
  const choices = candidates.filter((c) => !(c.acceptable && c.rank === 1) && files.has(c.account_id));
  return (
    <li className="flex flex-col gap-3 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800" data-testid="queue-card">
      <div className="flex flex-wrap items-center gap-2">
        {topFile ? (
          <input
            type="checkbox"
            name="payment_id"
            value={r.payment_id}
            form="bulk-accept"
            aria-label={`Sélectionner le paiement de ${amount}`}
            className="hidden h-4 w-4 sm:inline"
          />
        ) : null}
        <span className="text-lg font-semibold tabular-nums" data-testid="queue-amount">
          {amount}
        </span>
        <Badge tone={age.tone}>{age.text}</Badge>
        {r.status !== "matched" || r.review_reason ? (
          <Badge tone={reason.tone} testId="queue-reason">
            {reason.label}
          </Badge>
        ) : (
          <Badge tone="ok" testId="queue-reason">
            {r.match_method ? METHOD_LABEL[r.match_method] ?? r.match_method : "Rapproché"}
          </Badge>
        )}
        <span className="ml-auto text-xs text-zinc-600 dark:text-zinc-400">reçu le {frenchDate(r.booking_date)}</span>
      </div>
      <div className="min-w-0 text-sm">
        <p className="font-medium break-words">
          {r.payer_name ?? "Payeur non indiqué"}
          {r.payer_iban_end ? (
            <span className="ml-2 text-xs font-normal text-zinc-600 dark:text-zinc-400">IBAN …{r.payer_iban_end}</span>
          ) : null}
        </p>
        {r.remittance_text ? (
          <p className="break-words whitespace-pre-line text-zinc-700 dark:text-zinc-300" data-testid="queue-text">
            {highlight(r.remittance_text, refs).map((piece, i) =>
              piece.mark ? (
                <mark key={i} className="rounded bg-amber-100 px-0.5 dark:bg-amber-900 dark:text-amber-100">
                  {piece.text}
                </mark>
              ) : (
                <span key={i}>{piece.text}</span>
              ),
            )}
          </p>
        ) : (
          <p className="text-zinc-600 dark:text-zinc-400">Sans libellé</p>
        )}
        {r.creditor_reference ? <p className="font-mono text-xs">Réf. {formatRf(r.creditor_reference)}</p> : null}
      </div>

      {file ? (
        <div className="rounded-md bg-zinc-50 p-3 text-sm dark:bg-zinc-900" data-testid="queue-file">
          <p>
            Dossier <strong>{file.external_ref}</strong> · {file.client_name}
            {file.debtor_name ? ` · ${file.debtor_name}` : ""}
          </p>
          <p className="text-zinc-600 dark:text-zinc-400">
            {decision?.rule && r.match_method ? `Règle ${decision.rule} : ${METHOD_LABEL[r.match_method]} · ` : ""}
            solde {money(file.balance_minor, file.currency)}
          </p>
        </div>
      ) : null}
      {waitingFor ? (
        <p className="text-sm" data-testid="queue-waiting-file">
          Dossier attendu : <strong>{waitingFor.external_ref}</strong> · {waitingFor.client_name}
        </p>
      ) : null}
      {reason.help && (r.status !== "matched" || r.review_reason) ? (
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          {r.review_reason === "no_match" && !topFile ? NO_SUGGESTION_HELP : reason.help}
        </p>
      ) : null}

      {r.status === "unmatched" && r.review_reason && !["account_not_confirmed", "no_mandate"].includes(r.review_reason) ? (
        <div className="flex flex-col gap-3">
          {topFile ? (
            <div className="flex flex-col gap-1">
              <AcceptSuggestion paymentId={r.payment_id} amount={amount} file={topFile} idempotencyKey={randomUUID()} />
              <p className="text-xs text-zinc-600 dark:text-zinc-400">{signalText(top.rule, top.signals)}</p>
            </div>
          ) : null}
          {choices.length > 0 ? (
            <ul className="flex flex-col gap-2" data-testid="queue-candidates">
              {choices.map((c) => {
                const f = files.get(c.account_id)!;
                return (
                  <li key={c.rank} className="flex flex-col gap-2 rounded-md border border-zinc-200 p-3 text-sm dark:border-zinc-800">
                    <span>
                      {fileLabel(f)} · {f.client_name}
                      <span className="block text-xs text-zinc-600 dark:text-zinc-400">{signalText(c.rule, c.signals)}</span>
                    </span>
                    {f.status !== "staged" ? (
                      <ChooseFile paymentId={r.payment_id} amount={amount} file={f} idempotencyKey={randomUUID()} />
                    ) : (
                      <span className="text-xs">Dossier pas encore confirmé</span>
                    )}
                  </li>
                );
              })}
            </ul>
          ) : null}
          <SearchAndAssign paymentId={r.payment_id} amount={amount} idempotencyKey={randomUUID()} />
        </div>
      ) : null}
      {r.status === "matched" ? <Unassign paymentId={r.payment_id} idempotencyKey={randomUUID()} /> : null}
    </li>
  );
}
