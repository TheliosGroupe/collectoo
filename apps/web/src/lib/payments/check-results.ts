/**
 * M2c-6b-3b part 3 (ADR-0014 « M2c-6b-3b part 3 »; PR #39's known limit): « Contrôles » reads at most
 * CHECK_RESULTS_SHOWN results of a check run, in one total order, and says what it leaves out — per code, the run's own
 * count of results (`payment_check_run.summary`, the counts by code private.run_payment_checks writes when it finishes)
 * minus the rows read. Counts only: no amount is summed or invented for the results not read.
 */

/** How many results of a check run the page reads. */
export const CHECK_RESULTS_SHOWN = 200;

/**
 * The order the page reads a run's results in: anomalies first (« violation » after « alert » in reverse), then by
 * code, then within a code the oldest first (an undated result after every dated one), then by subject (one without a
 * subject first), then by the result's own id — a total order: the same results are read, and listed alike, every time.
 */
export const CHECK_RESULT_ORDER = [
  { column: "severity", ascending: false, nullsFirst: false },
  { column: "code", ascending: true, nullsFirst: false },
  { column: "oldest_days", ascending: false, nullsFirst: false },
  { column: "subject_id", ascending: true, nullsFirst: true },
  { column: "id", ascending: true, nullsFirst: false },
] as const;

/**
 * Review round 1 (tests-ui-3): CHECK_RESULT_ORDER applied to the page's query, key by key — the order the database
 * reads the run's results in, so the same CHECK_RESULTS_SHOWN are read every time (the rest counted, never listed).
 */
export function orderCheckResults<Q extends { order(column: string, options: { ascending: boolean; nullsFirst: boolean }): Q }>(
  query: Q,
): Q {
  let q = query;
  for (const o of CHECK_RESULT_ORDER) q = q.order(o.column, { ascending: o.ascending, nullsFirst: o.nullsFirst });
  return q;
}

type Ordered = {
  id: string;
  code: string;
  severity: string;
  subject_id: string | null;
  oldest_days: number | null;
};

function cmp<T extends string | number>(a: T, b: T): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/**
 * CHECK_RESULT_ORDER as a comparator. Review round 1 (tests-ui-3): groupCheckResults lists the rows read in it, so the
 * rows of a code come in one order whatever order the database returns them in.
 */
export function compareCheckResults(a: Ordered, b: Ordered): number {
  return (
    cmp(b.severity, a.severity) ||
    cmp(a.code, b.code) ||
    // the oldest first, an undated one last
    (a.oldest_days === b.oldest_days
      ? 0
      : a.oldest_days === null
        ? 1
        : b.oldest_days === null
          ? -1
          : cmp(b.oldest_days, a.oldest_days)) ||
    // no subject first
    (a.subject_id === b.subject_id
      ? 0
      : a.subject_id === null
        ? -1
        : b.subject_id === null
          ? 1
          : cmp(a.subject_id, b.subject_id)) ||
    cmp(a.id, b.id)
  );
}

export type CheckGroup<R> = { code: string; rows: R[]; hidden: number };

/**
 * The rows read, in CHECK_RESULT_ORDER (compareCheckResults: review round 1, tests-ui-3), grouped by code, each code
 * with the number of its results not listed (the run's count by code minus the rows read, never below 0); the codes
 * none of whose results is listed, with their count; the run's total and how many results are not listed. A run still
 * in progress has no counts: nothing is said hidden.
 */
export function groupCheckResults<R extends Ordered>(
  rows: R[],
  summary: Record<string, unknown> | null | undefined,
): { groups: CheckGroup<R>[]; unlisted: { code: string; count: number }[]; total: number; hidden: number } {
  const counts = new Map<string, number>();
  for (const [code, n] of Object.entries(summary ?? {})) {
    if (typeof n === "number" && Number.isInteger(n) && n > 0) counts.set(code, n);
  }
  const groups: CheckGroup<R>[] = [];
  const byCode = new Map<string, CheckGroup<R>>();
  for (const r of [...rows].sort(compareCheckResults)) {
    let g = byCode.get(r.code);
    if (!g) {
      g = { code: r.code, rows: [], hidden: 0 };
      byCode.set(r.code, g);
      groups.push(g);
    }
    g.rows.push(r);
  }
  for (const g of groups) g.hidden = Math.max(0, (counts.get(g.code) ?? 0) - g.rows.length);
  const unlisted = [...counts.entries()]
    .filter(([code]) => !byCode.has(code))
    .map(([code, count]) => ({ code, count }))
    .sort((a, b) => cmp(a.code, b.code));
  const hidden = groups.reduce((s, g) => s + g.hidden, 0) + unlisted.reduce((s, u) => s + u.count, 0);
  return { groups, unlisted, total: rows.length + hidden, hidden };
}

const count = (n: number) => new Intl.NumberFormat("fr-FR").format(n);

/** After the last row of a code whose other results are not listed. */
export function hiddenRowText(n: number): string {
  return n > 1
    ? `${count(n)} autres résultats de ce contrôle ne sont pas affichés.`
    : `${count(n)} autre résultat de ce contrôle n'est pas affiché.`;
}

/** A code none of whose results is listed. */
export function unlistedText(n: number): string {
  return n > 1
    ? `${count(n)} résultats de ce contrôle ne sont pas affichés.`
    : `${count(n)} résultat de ce contrôle n'est pas affiché.`;
}

/** Above the list, when the page does not list every result of the run. */
export function checkCutText(shown: number, total: number): string {
  return `Seuls les ${count(shown)} premiers résultats sont affichés, sur ${count(total)} : le nombre de résultats non affichés est indiqué pour chaque contrôle.`;
}
