import { describe, expect, it } from "vitest";
import {
  approvalSummary,
  blockerLabel,
  confirmedAgo,
  deadlineChip,
  failureLabel,
  percentText,
  runErrorCode,
  runStatus,
  runTab,
  sumMinor,
} from "./runs";

describe("runs (M2c-4 « Reversements »)", () => {
  it("names a run's state from its status and the job in flight, never « payé » before the debit", () => {
    expect(runStatus({ status: "draft", job: "prepare", prepared_at: null }).label).toBe("Préparation en cours");
    expect(runStatus({ status: "draft", job: "approve", prepared_at: "x" }).label).toBe("Validation en cours");
    expect(runStatus({ status: "draft", job: null, prepared_at: "x" }).label).toBe("Brouillon");
    expect(runStatus({ status: "approved", job: null, prepared_at: "x" }).label).toBe("Validé — virement ordonné");
    for (const s of ["approved", "sent", "booked", "cancelled"]) {
      expect(runStatus({ status: s, job: null, prepared_at: "x" }).label.toLowerCase()).not.toContain("payé");
    }
  });

  it("colours the deadline chip: green, orange from J-5, red from J-1 and past", () => {
    expect(deadlineChip("2026-11-09", "ok")).toEqual({ label: "Exécution au plus tard le 09/11/2026", tone: "ok" });
    expect(deadlineChip("2026-11-09", "soon")?.tone).toBe("action");
    expect(deadlineChip("2026-11-09", "critical")?.tone).toBe("error");
    expect(deadlineChip("2026-11-09", "late")).toEqual({ label: "Délai dépassé : 09/11/2026", tone: "error" });
    expect(deadlineChip(null, null)).toBeNull();
  });

  it("words blockers and back-to-draft reasons in French", () => {
    expect(blockerLabel("payout_account_unconfirmed")).toBe("IBAN de reversement en attente de confirmation");
    expect(blockerLabel("commission_input_error: x")).toContain("n'a pas pu être calculée");
    expect(failureLabel("balance_changed")).toBe("solde modifié depuis l'aperçu : actualisez");
    expect(failureLabel("payout_blocked:payout_account_missing")).toBe(
      "virement bloqué — Aucun IBAN de reversement confirmé",
    );
    expect(failureLabel("data_error:23514")).toContain("refusées");
  });

  it("adds minor units as BigInt text, never JS numbers", () => {
    expect(sumMinor(["16400000000000001", "1", null, "x"])).toBe("16400000000000002");
    expect(sumMinor([])).toBe("0");
  });

  it("writes rates in French without floats", () => {
    expect(percentText("0.15")).toBe("15 %");
    expect(percentText("0.0550")).toBe("5,5 %");
    expect(percentText("1")).toBe("100 %");
    expect(percentText("0.1234")).toBe("12,34 %");
    expect(percentText("bad")).toBe("bad");
  });

  it("maps command errors to codes, never the database's text", () => {
    expect(runErrorCode("remittance run refused: run_pending")).toBe("run_pending");
    expect(runErrorCode("remittance run refused: version_changed")).toBe("run_version_changed");
    expect(runErrorCode("remittance run refused: already_sent")).toBe("run_already_sent");
    expect(runErrorCode("not allowed")).toBe("not_allowed");
    expect(runErrorCode("anything else")).toBe("unknown");
  });

  it("says the approval's outcome per run", () => {
    expect(
      approvalSummary([
        { number: "RV-2026-000001", status: "queued", reason: null },
        { number: "RV-2026-000002", status: "refused", reason: "stale" },
      ]),
    ).toBe("1 en validation ; RV-2026-000002 refusé : le brouillon a changé depuis l'affichage");
  });

  it("reads the tab and the IBAN badge", () => {
    expect(runTab("en-cours")).toBe("en-cours");
    expect(runTab(["termines"])).toBe("termines");
    expect(runTab("nope")).toBe("a-valider");
    const now = new Date("2026-11-10T12:00:00Z");
    expect(confirmedAgo("2026-11-07T09:00:00Z", now)).toBe("IBAN confirmé il y a 3 j");
    expect(confirmedAgo("2026-11-10T08:00:00Z", now)).toBe("IBAN confirmé aujourd'hui");
    expect(confirmedAgo(null, now)).toBeNull();
  });
});
