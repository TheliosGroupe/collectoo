import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import {
  approvalSummary,
  blockerLabel,
  confirmedAgo,
  deadlineChip,
  failureLabel,
  failureNote,
  lateReasonRequired,
  percentText,
  prepareFailed,
  refundNote,
  runBusy,
  runErrorCode,
  runStatus,
  runTab,
  sumMinor,
  summaryTone,
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

  it("says the approval's outcome per run, with the count refused", () => {
    expect(
      approvalSummary([
        { number: "RV-2026-000001", status: "queued", reason: null },
        { number: "RV-2026-000002", status: "refused", reason: "stale" },
      ]),
    ).toEqual({
      summary: "1 en validation ; RV-2026-000002 refusé : le brouillon a changé depuis l'affichage",
      queued: 1,
      refused: 1,
    });
    expect(approvalSummary([{ number: "RV-2026-000001", status: "queued", reason: null }])).toEqual({
      summary: "1 en validation",
      queued: 1,
      refused: 0,
    });
  });

  it("colours the approval's outcome: green when all are queued, orange when some are refused, red when all are", () => {
    expect(summaryTone({ queued: 2, refused: 0 })).toBe("ok");
    expect(summaryTone({ queued: 1, refused: 1 })).toBe("action");
    expect(summaryTone({ queued: 0, refused: 1 })).toBe("error");
  });

  it("words every refusal of the approval in French, never the code (review M2c-4 tests-ui#4, C1)", () => {
    const words: Record<string, string> = {
      unknown_run: "reversement introuvable",
      not_draft: "n'est plus un brouillon : rechargez",
      preparing: "préparation en cours : réessayez",
      approval_in_progress: "déjà en cours de validation",
      payout_blocked: "virement bloqué",
      busy: "traitement en cours sur ce reversement : réessayez",
      vat_option_changed: "option TVA modifiée depuis la préparation : actualisez",
      client_status_changed: "situation du client modifiée depuis la préparation : actualisez",
      late_reason_required: "motif du retard requis",
    };
    for (const [code, text] of Object.entries(words)) expect(failureLabel(code), code).toBe(text);
    for (const code of [
      "stale",
      "not_prepared",
      "negative_net",
      "execution_date_passed",
      "execution_date_not_business_day",
      "execution_date_after_cutoff",
      "vat_rate_changed",
      "commission_blocked",
      "payout_account_changed",
      "balance_changed",
      "history_changed",
      "documents_changed",
      "items_changed",
      "approval_timeout",
      "approval_failed",
      "prepare_failed",
    ])
      expect(failureLabel(code), code).not.toBe(code);
    expect(failureLabel("payout_blocked:client_status:death")).toBe("virement bloqué — Décès du client enregistré");
    const { summary } = approvalSummary([
      { number: "RV-2026-000003", status: "refused", reason: "approval_in_progress" },
      { number: "RV-2026-000004", status: "refused", reason: "busy" },
    ]);
    expect(summary).toBe(
      "0 en validation ; RV-2026-000003 refusé : déjà en cours de validation ; RV-2026-000004 refusé : traitement en cours sur ce reversement : réessayez",
    );
    expect(summary).not.toMatch(/[a-z]+_[a-z]+/);
  });

  it("gives a remittance command's lock timeout its own words, not the payments' (review M2c-4 tests-ui#5)", () => {
    expect(runErrorCode("canceling statement due to lock timeout")).toBe("run_busy");
    expect(runErrorCode('could not obtain lock on row in relation "remittance_run"')).toBe("run_busy");
    expect(errorText("run_busy")).toContain("reversement");
    expect(errorText("run_busy")).not.toContain("rapprochement");
  });

  it("shows a failed preparation as such, not as a preparation running for ever (review M2c-4 tests-ui#3, C4)", () => {
    const failed = {
      status: "draft",
      job: null,
      prepared_at: null,
      last_failure: { code: "prepare_failed", step: "prepare" },
    };
    expect(prepareFailed(failed)).toBe(true);
    expect(runStatus(failed)).toEqual({ label: "Préparation échouée — actualisez", tone: "error" });
    expect(runBusy(failed)).toBe(false);
    // still preparing: the job is in flight, or a first prepare not yet picked up
    expect(runStatus({ status: "draft", job: "prepare", prepared_at: null, last_failure: null }).label).toBe(
      "Préparation en cours",
    );
    expect(runBusy({ status: "draft", job: "prepare", prepared_at: null, last_failure: null })).toBe(true);
    expect(runBusy({ status: "draft", job: null, prepared_at: null, last_failure: null })).toBe(true);
    // a prepare retried by « Actualiser » after a failure is running again
    expect(prepareFailed({ ...failed, job: "prepare" })).toBe(false);
    expect(runBusy({ ...failed, job: "prepare" })).toBe(true);
    // an approval sent back to draft is not a failed preparation
    const back = { status: "draft", job: null, prepared_at: "x", last_failure: { code: "stale", step: "approve" } };
    expect(prepareFailed(back)).toBe(false);
    expect(runStatus(back).label).toBe("Brouillon");
    expect(runBusy(back)).toBe(false);
    expect(runBusy({ status: "approved", job: null, prepared_at: "x", last_failure: null })).toBe(false);
    expect(runBusy({ status: "draft", job: "approve", prepared_at: "x", last_failure: null })).toBe(true);
    // the card's note says what to do, not « Renvoyé en brouillon » for a draft never prepared
    expect(failureNote(failed.last_failure)).toBe("Préparation échouée : la préparation a échoué — « Actualiser » la relance");
    expect(failureNote({ code: "data_error:23514", step: "prepare" })).toContain("refusées par la base");
    expect(failureNote(back.last_failure)).toBe("Renvoyé en brouillon : le brouillon a changé depuis l'affichage");
    expect(failureNote(null)).toBeNull();
  });

  it("asks the reason for a late approval, an N = 0 run when today is past its date (review M2c-4 money#3)", () => {
    const transfer = { net_minor: "65601", earliest_latest_execution_date: "2026-12-01" };
    const settled = { net_minor: "0", earliest_latest_execution_date: "2026-12-01" };
    // N > 0: the requested execution date decides
    expect(lateReasonRequired([transfer], "2026-12-01", "2026-11-30")).toBe(false);
    expect(lateReasonRequired([transfer], "2026-12-02", "2026-11-30")).toBe(true);
    // N = 0: settled at approval, today (Paris) decides, whatever the date requested
    expect(lateReasonRequired([settled], "2026-12-04", "2026-12-01")).toBe(false);
    expect(lateReasonRequired([settled], "2026-12-03", "2026-12-02")).toBe(true);
    expect(lateReasonRequired([settled, transfer], "2026-11-30", "2026-12-02")).toBe(true);
    expect(lateReasonRequired([{ net_minor: "0", earliest_latest_execution_date: null }], "2026-12-03", "2026-12-02")).toBe(
      false,
    );
    expect(lateReasonRequired([], "2026-12-03", "2026-12-02")).toBe(false);
  });

  it("never says a credit note's refund was paid before the run is booked (review M2c-4 legal#5)", () => {
    for (const status of ["draft", "approved", "sent"]) {
      const note = refundNote({ status, refund_minor: "1200", currency: "EUR" });
      expect(note, status).toMatch(/^remboursement d'avoir inclus dans le virement : 12,00\s€$/);
      expect(note, status).not.toContain("remboursé");
    }
    expect(refundNote({ status: "booked", refund_minor: "1200", currency: "EUR" })).toMatch(/^avoir remboursé 12,00\s€$/);
    expect(refundNote({ status: "approved", refund_minor: "0", currency: "EUR" })).toBeNull();
    expect(refundNote({ status: "draft", refund_minor: null, currency: "EUR" })).toBeNull();
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
