import { describe, expect, it } from "vitest";
import {
  CHECK_RESULTS_SHOWN,
  CHECK_RESULT_ORDER,
  checkCutText,
  compareCheckResults,
  groupCheckResults,
  hiddenRowText,
  orderCheckResults,
  unlistedText,
} from "./check-results";

/**
 * M2c-6b-3b part 3 (ADR-0014 « M2c-6b-3b part 3 »; PR #39's known limit): « Contrôles » reads at most 200 results of a
 * check run. What it leaves out is said: per code, how many results exist beyond those listed — the run's own count by
 * code (`payment_check_run.summary`, written by private.run_payment_checks) minus the rows read, never an amount — and
 * the rows within a code come in one order, whatever the database returns ties in.
 */
type Row = { id: string; code: string; severity: string; subject_id: string | null; oldest_days: number | null };

const row = (id: string, code: string, oldest: number | null = null, subject: string | null = null, severity = "alert"): Row => ({
  id,
  code,
  severity,
  subject_id: subject,
  oldest_days: oldest,
});

describe("« Contrôles » beyond its 200 results (M2c-6b-3b part 3)", () => {
  it("reads 200 results at most, in a total order: anomalies first, then by code, then the oldest first, then the subject, then the result", () => {
    expect(CHECK_RESULTS_SHOWN).toBe(200);
    expect(CHECK_RESULT_ORDER.map((o) => [o.column, o.ascending])).toEqual([
      ["severity", false],
      ["code", true],
      ["oldest_days", false],
      ["subject_id", true],
      ["id", true],
    ]);
    // the age without a value after every dated one; the subject without one first (as ascending reads nulls last in
    // PostgreSQL, say it explicitly whichever the default)
    expect(CHECK_RESULT_ORDER.find((o) => o.column === "oldest_days")?.nullsFirst).toBe(false);
    expect(CHECK_RESULT_ORDER.find((o) => o.column === "subject_id")?.nullsFirst).toBe(true);
    // the last key is the result's own (unique): no tie left to the database
    expect(CHECK_RESULT_ORDER.at(-1)?.column).toBe("id");
  });

  it("orders the rows of a code the same whatever order they come in", () => {
    const rows = [
      row("r5", "transfer_unknown", 3, "s2"),
      row("r1", "transfer_unknown", null, "s1"),
      row("r4", "transfer_unknown", 3, "s1"),
      row("r2", "transfer_unknown", 9, "s9"),
      row("r3", "transfer_unknown", 3, null),
      row("r0", "remittance_breach_held", 1, "s0"),
      row("v1", "bank_line_booked", null, "s0", "violation"),
    ];
    const expected = ["v1", "r0", "r2", "r3", "r4", "r5", "r1"];
    for (let k = 0; k < rows.length; k++) {
      const shuffled = [...rows.slice(k), ...rows.slice(0, k)].reverse();
      expect([...shuffled].sort(compareCheckResults).map((r) => r.id)).toEqual(expected);
    }
    // two results of one code, one age and one subject: their own ids decide
    expect([row("b", "x", 1, "s"), row("a", "x", 1, "s")].sort(compareCheckResults).map((r) => r.id)).toEqual(["a", "b"]);
  });

  it("asks the database for the results in that order, key by key (review round 1, tests-ui-3: the page's query)", () => {
    // a query builder that records what it is asked, as supabase-js's: each .order returns the builder
    const calls: [string, { ascending: boolean; nullsFirst: boolean }][] = [];
    const builder = {
      order(column: string, options: { ascending: boolean; nullsFirst: boolean }) {
        calls.push([column, options]);
        return builder;
      },
    };
    expect(orderCheckResults(builder)).toBe(builder);
    expect(calls).toEqual([
      ["severity", { ascending: false, nullsFirst: false }],
      ["code", { ascending: true, nullsFirst: false }],
      ["oldest_days", { ascending: false, nullsFirst: false }],
      ["subject_id", { ascending: true, nullsFirst: true }],
      ["id", { ascending: true, nullsFirst: false }],
    ]);
  });

  it("lists the rows of a code in that order whatever order the database returns them in (review round 1, tests-ui-3)", () => {
    const rows = [
      row("r5", "transfer_unknown", 3, "s2"),
      row("r1", "transfer_unknown", null, "s1"),
      row("r4", "transfer_unknown", 3, "s1"),
      row("r2", "transfer_unknown", 9, "s9"),
      row("r3", "transfer_unknown", 3, null),
    ];
    for (let k = 0; k < rows.length; k++) {
      const read = [...rows.slice(k), ...rows.slice(0, k)].reverse();
      const g = groupCheckResults(read, { transfer_unknown: 7 });
      expect(g.groups.map((x) => [x.code, x.rows.map((r) => r.id), x.hidden])).toEqual([
        ["transfer_unknown", ["r2", "r3", "r4", "r5", "r1"], 2],
      ]);
    }
  });

  it("counts, per code, the results the page does not list, from the run's own count by code", () => {
    const listed = [
      ...Array.from({ length: 150 }, (_, k) => row(`a${String(k).padStart(3, "0")}`, "bank_line_unbooked")),
      ...Array.from({ length: 50 }, (_, k) => row(`b${String(k).padStart(3, "0")}`, "transfer_unknown")),
    ];
    const g = groupCheckResults(listed, { bank_line_unbooked: 150, transfer_unknown: 53, remittance_breach_held: 12 });
    expect(g.groups.map((x) => [x.code, x.rows.length, x.hidden])).toEqual([
      ["bank_line_unbooked", 150, 0],
      ["transfer_unknown", 50, 3],
    ]);
    // a code none of whose results is listed: counted, never dropped
    expect(g.unlisted).toEqual([{ code: "remittance_breach_held", count: 12 }]);
    expect(g.total).toBe(215);
    expect(g.hidden).toBe(15);
    // the rows keep the order they were read in
    expect(g.groups[1].rows[0].id).toBe("b000");
  });

  it("says nothing is cut when every result is listed, and reads no count it does not have", () => {
    const rows = [row("a", "transfer_unknown"), row("b", "transfer_unknown")];
    expect(groupCheckResults(rows, { transfer_unknown: 2 })).toMatchObject({ total: 2, hidden: 0, unlisted: [] });
    // a run still in progress has no counts yet: the rows read are all there is to say
    expect(groupCheckResults(rows, null)).toMatchObject({ total: 2, hidden: 0, unlisted: [] });
    // a count below what was read (never written so) hides nothing
    expect(groupCheckResults(rows, { transfer_unknown: 1 }).groups[0].hidden).toBe(0);
    // a count that is not a number is not one
    expect(groupCheckResults(rows, { transfer_unknown: "9" }).groups[0].hidden).toBe(0);
  });

  it("words what is not listed in French, the noun agreeing with its number, with no amount", () => {
    expect(hiddenRowText(1)).toBe("1 autre résultat de ce contrôle n'est pas affiché.");
    expect(hiddenRowText(3)).toBe("3 autres résultats de ce contrôle ne sont pas affichés.");
    expect(unlistedText(1)).toBe("1 résultat de ce contrôle n'est pas affiché.");
    expect(unlistedText(12)).toBe("12 résultats de ce contrôle ne sont pas affichés.");
    expect(checkCutText(200, 215)).toBe(
      "Seuls les 200 premiers résultats sont affichés, sur 215 : le nombre de résultats non affichés est indiqué pour chaque contrôle.",
    );
    // thousands as the page writes every count (fr-FR)
    expect(checkCutText(200, 2215)).toContain("sur 2 215 :");
    for (const t of [hiddenRowText(3), unlistedText(12), checkCutText(200, 215)]) expect(t).not.toMatch(/€|EUR/);
  });
});
