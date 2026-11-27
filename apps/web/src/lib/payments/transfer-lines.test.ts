// M2c-6b-2b (plan docs/design/m2c-6b-2-plan.md §3.10, §3.13, §7.2, §8.3): every refusal the ops command can raise has
// its French label; the two SQLSTATEs and the re-raised lock waits map to their own codes; every booking kind has a
// decision label.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { DECISION_LABEL, decisionLabel, LINK_KIND } from "./debits";
import { TRANSFER_LINE_REFUSAL, transferLineErrorCode, transferLineErrorText } from "./transfer-lines";

const MIGRATION = readFileSync(
  join(__dirname, "../../../../../supabase/migrations/20261117100000_transfer_line_ops.sql"),
  "utf8",
);

/** The codes the migration can refuse with: `v_why := '<code>'`, the parse/pre/tenant returns, the re-raised waits. */
function migrationCodes(): Set<string> {
  const codes = new Set<string>();
  for (const m of MIGRATION.matchAll(/v_why := '([a-z_]+)'/g)) codes.add(m[1]);
  for (const m of MIGRATION.matchAll(/refused: ([a-z_]+)/g)) codes.add(m[1]);
  for (const m of MIGRATION.matchAll(/return '([a-z_]+)';/g)) codes.add(m[1]);
  for (const m of MIGRATION.matchAll(/then '(allocation_busy|client_unknown)'/g)) codes.add(m[1]);
  for (const m of MIGRATION.matchAll(/else '(busy|client_unknown)' end/g)) codes.add(m[1]);
  return codes;
}

describe("the command's refusals (§3.10)", () => {
  it("finds the refusals of the migration (the reading of the SQL is not empty)", () => {
    const codes = migrationCodes();
    for (const c of ["bad_request", "lot_too_large", "split_changed", "posting_failed", "busy", "allocation_busy"])
      expect(codes).toContain(c);
    expect(codes.size).toBeGreaterThan(40);
  });
  it("every `transfer line booking refused:` code of the migration has a French label", () => {
    const missing = [...migrationCodes()].filter((c) => !(c in TRANSFER_LINE_REFUSAL));
    expect(missing).toEqual([]);
  });
  it("every label is French, ends with a full stop and names no database word", () => {
    for (const [code, text] of Object.entries(TRANSFER_LINE_REFUSAL)) {
      expect(text, code).toMatch(/\.$/);
      expect(text, code).not.toMatch(/transfer_|bank_|null|uuid|SQL/);
    }
  });
  it("the command's own text gives its code, with a detail after it or not", () => {
    expect(transferLineErrorCode({ message: "transfer line booking refused: amount_differs" })).toBe("amount_differs");
    expect(
      transferLineErrorCode({ message: "transfer line booking refused: posting_failed (P0001: LG008 …)", code: "23514" }),
    ).toBe("posting_failed");
    expect(transferLineErrorCode({ message: "transfer line booking refused: client_run_cancellable", code: "23514" })).toBe(
      "client_run_cancellable",
    );
  });
  it("55P03 → busy, 57014 → timeout, the re-raised allocation lock → allocation_busy (critic2 CSO2-6)", () => {
    expect(transferLineErrorCode({ code: "55P03", message: "" })).toBe("busy");
    expect(transferLineErrorCode({ code: "57014", message: "" })).toBe("timeout");
    expect(transferLineErrorCode({ code: "55P03", message: "canceling statement due to lock timeout" })).toBe("busy");
    expect(transferLineErrorCode({ code: "55P03", message: "could not obtain lock on row" })).toBe("busy");
    expect(transferLineErrorCode({ code: "57014", message: "canceling statement due to statement timeout" })).toBe(
      "timeout",
    );
    expect(
      transferLineErrorCode({ code: "55P03", message: "transfer line booking refused: allocation_busy" }),
    ).toBe("allocation_busy");
    expect(transferLineErrorCode({ code: "55P03", message: "transfer line booking refused: busy" })).toBe("busy");
    expect(TRANSFER_LINE_REFUSAL.allocation_busy).toContain("imputation ou une validation de reversements");
    expect(TRANSFER_LINE_REFUSAL.allocation_busy).not.toBe(TRANSFER_LINE_REFUSAL.busy);
    expect(TRANSFER_LINE_REFUSAL.timeout).toContain("n'a rien enregistré");
  });
  it("a deadlock or a serialisation failure is busy: nothing was recorded, retry (review CSR-1)", () => {
    expect(transferLineErrorCode({ code: "40P01", message: "deadlock detected" })).toBe("busy");
    expect(transferLineErrorCode({ code: "40001", message: "could not serialize access due to concurrent update" })).toBe(
      "busy",
    );
    expect(transferLineErrorCode({ message: "deadlock detected" })).toBe("busy");
  });
  it("the direction and the transfer's kind have labels true of what is checked (review LT-6)", () => {
    expect(TRANSFER_LINE_REFUSAL.wrong_direction).toContain("ligne de ce sens");
    expect(TRANSFER_LINE_REFUSAL.transfer_kind_differs).toContain("n'est pas de ce type");
    expect(TRANSFER_LINE_REFUSAL.transfer_unknown).toContain("ne l'a pas comptabilisé hors reversement");
    // the line's kind (a refund, a direct debit, a payment's return) is not the direction: our payout's own flagged
    // return is refused wrong_direction, never « pas un virement émis »
    expect(TRANSFER_LINE_REFUSAL.not_a_transfer_line).not.toBe(TRANSFER_LINE_REFUSAL.wrong_direction);
    expect(transferLineErrorCode({ message: "transfer line booking refused: transfer_kind_differs" })).toBe(
      "transfer_kind_differs",
    );
  });
  it("« not allowed » and the motif keep their labels; anything else is unknown, never the raw text", () => {
    expect(transferLineErrorText(transferLineErrorCode({ code: "42501", message: "not allowed" }))).toBe(
      "Action non autorisée pour votre rôle.",
    );
    expect(transferLineErrorText(transferLineErrorCode({ code: "23514", message: "a reason is required" }))).toBe(
      "Indiquez un motif.",
    );
    const unknown = transferLineErrorText(transferLineErrorCode({ code: "XX000", message: "relation foo does not exist" }));
    expect(unknown).not.toContain("relation");
    expect(transferLineErrorText("transfer_not_a_code")).toBe(unknown);
  });
  it("the waits and the lot cap say what to do (critic CSO-3, CSO2-3)", () => {
    expect(transferLineErrorText("lot_too_large")).toContain("Ce lot ou cette écriture");
    expect(transferLineErrorText("busy")).toContain("réessayez");
  });
});

describe("the decision labels (§3.13)", () => {
  const KINDS = [
    "payout",
    "sweep",
    "unplanned_payout",
    "unplanned_sweep",
    "payout_returned",
    "sweep_returned",
    "unplanned_payout_returned",
    "unplanned_sweep_returned",
    "fee",
    // M2c-7e-3 review round 1 (TUI-2, R3): « Règlement du client » (7c-1's lines, 7e-3's exit (b)), shown as its code
    // before — this list had missed it
    "client_payment",
  ];
  it("every booking kind ops or the job book has a label", () => {
    for (const k of KINDS) expect(DECISION_LABEL[k], k).toBeTruthy();
    expect(Object.keys(DECISION_LABEL).sort()).toEqual([...KINDS].sort());
    expect(decisionLabel("unplanned_payout", "transfer_out")).toBe("Virement hors reversement");
    expect(decisionLabel("payout_returned", "return")).toBe("Reversement revenu");
  });
  it("the fee keeps its label (M2c-1)", () => {
    expect(DECISION_LABEL.fee).toBe(LINK_KIND.fee);
    expect(decisionLabel("fee", "other_debit")).toBe(LINK_KIND.fee);
  });
  it("a line booked in several parts says each, in their order", () => {
    expect(decisionLabel("payout+fee", "transfer_out")).toBe(
      "Débit d'un reversement + Frais bancaires (à la charge du cabinet)",
    );
    expect(decisionLabel("payout+payout+unplanned_payout", "batch_unsplit")).toBe(
      "Débit d'un reversement + Débit d'un reversement + Virement hors reversement",
    );
    expect(decisionLabel("something_new", "x")).toBe("something_new");
  });
});
