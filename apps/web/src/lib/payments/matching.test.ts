import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { money } from "@/lib/payments/statements";
import {
  QUEUE_PAGE_SIZE,
  REASON_FILTERS,
  acceptNotice,
  ageBadge,
  autoShare,
  eurosToMinor,
  fileLabel,
  gatingOutcome,
  lastPage,
  outcomeText,
  parseAcceptItems,
  formatRf,
  highlight,
  matchingErrorCode,
  minorToEuros,
  pendingText,
  queueHref,
  queueQuery,
  refKey,
  reviewReason,
  signalText,
} from "./matching";

const FILE = {
  account_id: "a",
  external_ref: "M-0042",
  status: "in_collection",
  client_name: "Martin SAS",
  debtor_name: "Durand SARL",
  currency: "EUR",
  balance_minor: "80000",
  pending_minor: "0",
  rf: "RF60482193057612",
  servicing_start: "2026-01-01",
  holds: [] as string[],
};

describe("queue labels", () => {
  it("words every reason the queue can show, with what ops do", () => {
    for (const r of REASON_FILTERS) {
      expect(reviewReason(r.value).label).not.toBe(r.value);
      expect(reviewReason(r.value).help.length).toBeGreaterThan(10);
    }
    expect(reviewReason(null).label).toBe("Rapprochement en cours");
    expect(reviewReason("no_mandate").help).toContain("1342-2");
  });

  it("ages a payment from its booking date; from 20 days the remittance month is close", () => {
    expect(ageBadge(3)).toEqual({ text: "J+3", tone: "neutral" });
    expect(ageBadge(12).tone).toBe("action");
    expect(ageBadge(20).tone).toBe("error");
  });

  it("states the one-tap suggestion with the file, the debtor and its balance (no float)", () => {
    expect(fileLabel(FILE)).toBe(`M-0042 · Durand SARL · solde ${money("80000", "EUR")}`);
    expect(pendingText(FILE)).toBeNull();
    expect(pendingText({ ...FILE, pending_minor: "12345678901234567" })).toBe(
      `dont ${money("12345678901234567", "EUR")} déjà reçus, à imputer`,
    );
    expect(money("12345678901234567", "EUR")).toMatch(/^123.456.789.012.345,67.€$/);
  });

  it("explains why a file was proposed", () => {
    expect(signalText("R5", { amount: "account", similarity: "0.92" })).toBe(
      "Montant et nom : montant égal au solde du dossier · nom proche à 92 %",
    );
    expect(signalText("R3", { tokens: ["FA202600042"], why: "not_corroborated" })).toBe(
      "Numéro de facture ou de dossier : cite FA202600042 · sans second indice",
    );
    expect(signalText("R1", { rf: ["RF60482193057612"] })).toBe("Référence RF structurée : référence RF60 4821 9305 7612");
  });

  it("formats an RF reference in groups of four", () => {
    expect(formatRf("RF60482193057612")).toBe("RF60 4821 9305 7612");
  });
});

describe("highlighting the references the rules read", () => {
  it("marks the words that are a cited reference, or part of one", () => {
    const pieces = highlight("VIR rf60 4821 9305 7612 et FA-2026-00042 merci", ["RF60482193057612", "FA202600042"]);
    expect(pieces.filter((p) => p.mark).map((p) => p.text)).toEqual(["rf60 4821 9305 7612", "FA-2026-00042"]);
    expect(pieces.map((p) => p.text).join("")).toBe("VIR rf60 4821 9305 7612 et FA-2026-00042 merci");
  });

  it("marks nothing without a reference, and never a 1 or 2 character word", () => {
    expect(highlight("VIREMENT 12", [])).toEqual([{ text: "VIREMENT 12", mark: false }]);
    expect(highlight("A 12", ["A12345"]).some((p) => p.mark)).toBe(false);
  });

  it("reads references as SQL and the worker do", () => {
    expect(refKey("fa-2026/00042 é°")).toBe("FA202600042");
  });
});

describe("errors of the commands", () => {
  it.each([
    ["not allowed", "not_allowed"],
    ["a reason is required", "reason_required"],
    ["the payment is already matched: unassign it first", "already_matched"],
    ["the file is not confirmed yet", "file_not_confirmed"],
    ["one file for the whole payment (splitting comes with allocation)", "split_not_available"],
    ["unknown file", "unknown_file"],
    ["the payment is not matched", "not_matched"],
    ["money of this payment is allocated: reverse the allocation first", "payment_allocated"],
    ["canceling statement due to lock timeout", "busy"],
    ["invalid designation: invoices of this file only", "designation_invalid"],
    ["boom", "unknown"],
  ] as const)("%s -> %s", (message, code) => {
    expect(matchingErrorCode(message)).toBe(code);
    expect(errorText(code)).not.toBe("");
  });
});

describe("the queue's URL", () => {
  it("reads filters, refusing anything else", () => {
    expect(queueQuery({})).toEqual({
      onglet: "a-traiter",
      motif: null,
      client: null,
      min: null,
      max: null,
      age: null,
      page: 1,
    });
    const q = queueQuery({
      onglet: "rapproches",
      motif: "ambiguous",
      client: "00000000-0000-0000-0000-0000000000a1",
      min: "1 234,5",
      max: "x",
      age: "20",
      page: "2",
    });
    expect(q).toMatchObject({ onglet: "rapproches", motif: "ambiguous", min: BigInt(123450), max: null, age: 20, page: 2 });
    expect(queueQuery({ motif: "drop table", client: "1", page: "0" })).toMatchObject({ motif: null, client: null, page: 1 });
  });

  it("writes them back, defaults left out", () => {
    const q = queueQuery({ min: "10", age: "5" });
    expect(queueHref(q)).toBe("/backoffice/encaissements/a-traiter?min=10%2C00&age=5");
    expect(queueHref(q, { onglet: "rapproches", min: null, age: null })).toBe(
      "/backoffice/encaissements/a-traiter?onglet=rapproches",
    );
  });

  it("converts euros typed in a filter to minor units and back, exactly", () => {
    expect(eurosToMinor("999 999 999 999,99")).toBe(BigInt("99999999999999"));
    expect(eurosToMinor("12.3")).toBe(BigInt(1230));
    expect(eurosToMinor("-5")).toBeNull();
    expect(minorToEuros(BigInt(1230))).toBe("12,30");
  });

  it("gives the share matched automatically, rounded down", () => {
    expect(autoShare(955, 1000)).toBe("95 %");
    expect(autoShare(0, 0)).toBe("–");
  });
});


describe("what the confirmation sheet promises (= the SQL gating, first that applies)", () => {
  const PAID = { currency: "EUR", booking_date: "2026-10-05" };
  it("allocation only when the gating lets the payment through", () => {
    expect(gatingOutcome(FILE, PAID)).toBeNull();
    expect(outcomeText(null)).toContain("imputé sur ses factures");
  });
  it.each([
    [{ status: "staged" }, PAID, "account_not_confirmed"],
    [{ status: "closed_recalled" }, PAID, "account_closed"],
    [{ status: "closed_paid", holds: ["surendettement"] }, PAID, "account_closed"],
    [{}, { ...PAID, currency: "USD" }, "currency_mismatch"],
    [{}, { ...PAID, booking_date: "2025-12-31" }, "before_servicing_start"],
    [{ servicing_start: null }, PAID, "before_servicing_start"],
    [{ holds: ["collective_proceeding"] }, PAID, "hold_blocks_allocation"],
    [{ pending_minor: "80000" }, PAID, "nothing_due"],
    [{ balance_minor: "0" }, PAID, "nothing_due"],
    [{ balance_minor: "99999999999999999", pending_minor: "99999999999999998" }, PAID, null],
  ] as const)("%o, paid %o -> %s", (change, paid, reason) => {
    expect(gatingOutcome({ ...FILE, ...change }, paid)).toBe(reason);
  });
  it("never promises an allocation the gating holds or refuses", () => {
    for (const reason of ["account_closed", "currency_mismatch", "before_servicing_start", "hold_blocks_allocation", "nothing_due"]) {
      expect(outcomeText(reason)).toContain("attente");
      expect(outcomeText(reason)).not.toContain("imputé sur ses factures");
    }
    expect(outcomeText("hold_blocks_allocation")).toContain("procédure collective");
    expect(outcomeText("account_not_confirmed")).toContain("pas encore confirmé");
  });
});

describe("accepting suggestions: the file ops saw, and what was skipped", () => {
  const P = "00000000-0000-0000-0000-0000000000f1";
  const A = "00000000-0000-0000-0000-0000000000a1";
  it("reads « payment:file » pairs, refusing anything else", () => {
    expect(parseAcceptItems([`${P}:${A}`])).toEqual([{ payment_id: P, account_id: A }]);
    expect(parseAcceptItems([P])).toBeNull();
    expect(parseAcceptItems([`${P}:x`])).toBeNull();
    expect(parseAcceptItems([])).toEqual([]);
  });
  it("says how many were accepted", () => {
    expect(acceptNotice(1, [])).toEqual({ text: "1 suggestion acceptée.", tone: "ok" });
    expect(acceptNotice(3, []).text).toBe("3 suggestions acceptées.");
  });
  it("says which were skipped, and why", () => {
    const n = acceptNotice(2, [
      { payment_id: P, reason: "suggestion_changed" },
      { payment_id: A, reason: "suggestion_changed" },
      { payment_id: A, reason: "not_waiting" },
    ]);
    expect(n.tone).toBe("action");
    expect(n.text).toBe(
      "2 suggestions acceptées ; 3 paiements ignorés : suggestion modifiée entre-temps (2), déjà traité (1). Vérifiez les propositions à jour.",
    );
    expect(acceptNotice(0, [{ payment_id: P, reason: "no_suggestion" }]).text).toBe(
      "Aucune suggestion acceptée ; 1 paiement ignoré : plus de suggestion (1). Vérifiez les propositions à jour.",
    );
  });
  it("asks to tick a payment when none is", () => {
    expect(errorText("none_selected")).toBe("Cochez au moins un paiement.");
  });
});

describe("a page past the last one", () => {
  it("knows the last page of a total", () => {
    expect(lastPage(0)).toBe(1);
    expect(lastPage(QUEUE_PAGE_SIZE)).toBe(1);
    expect(lastPage(QUEUE_PAGE_SIZE + 1)).toBe(2);
  });
});
