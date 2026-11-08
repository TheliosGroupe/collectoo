import { describe, expect, it } from "vitest";
import {
  LINE_FILTERS,
  STATEMENT_STATUS_FILTERS,
  acceptFor,
  bankCheckText,
  importErrorText,
  lineFilterOr,
  lineInFilter,
  lineState,
  maskedIban,
  money,
  signedMoney,
  statementListHref,
  statementListQuery,
  statementStatus,
  uploadErrorText,
  warningText,
} from "./statements";

/** formatMoneyFr uses no-break spaces; compare with plain ones. */
const plain = (s: string) => s.replace(/[\u00a0\u202f]/g, " ");

describe("statement amounts", () => {
  it("formats integer minor units given as text, never through a JS number", () => {
    expect(plain(money("123450", "EUR"))).toBe("1 234,50 €");
    expect(plain(money("-265", "EUR"))).toBe("-2,65 €");
    // beyond Number.MAX_SAFE_INTEGER: still exact
    expect(plain(money("900719925474099312", "EUR"))).toBe("9 007 199 254 740 993,12 €");
    expect(plain(money(null, "EUR"))).toBe("–");
    expect(plain(money("12.5", "EUR"))).toBe("–");
  });

  it("signs a line by its direction", () => {
    expect(plain(signedMoney("credit", "1000", "EUR"))).toBe("+ 10,00 €");
    expect(plain(signedMoney("debit", "150", "EUR"))).toBe("− 1,50 €");
  });
});

describe("statement and line states", () => {
  it("words the statuses", () => {
    expect(statementStatus("imported")).toEqual({ label: "Importé", tone: "ok" });
    expect(statementStatus("uploaded").tone).toBe("busy");
    expect(statementStatus("rejected").tone).toBe("error");
  });

  it("tells booked payments from lines that wait", () => {
    expect(lineState({ kind: "debtor_credit", direction: "credit", has_payment: true })).toEqual({
      kind: "Encaissement",
      state: "Comptabilisé · à affecter",
      tone: "ok",
    });
    expect(lineState({ kind: "batch_unsplit", direction: "credit", has_payment: true }).state).toBe(
      "Comptabilisé · à affecter",
    );
    expect(lineState({ kind: "suspected_duplicate", direction: "credit", has_payment: false }).state).toBe(
      "Retenu : doublon possible",
    );
    expect(lineState({ kind: "other_debit", direction: "debit", has_payment: false })).toEqual({
      kind: "Débit (frais, autre)",
      state: "Non comptabilisé · à classer",
      tone: "action",
    });
  });
});

describe("bank balance check (I9)", () => {
  const base = { as_of: "2026-10-02", closing_minor: "16850", cash_minor: "19500" };
  it("reconciled, with or without lines to classify", () => {
    expect(
      plain(bankCheckText({ ...base, unposted_minor: "0", unposted_lines: 0, difference_minor: "0" }, "EUR").text),
    ).toBe("Solde de clôture rapproché ✓");
    expect(
      plain(bankCheckText({ ...base, unposted_minor: "-2650", unposted_lines: 2, difference_minor: "0" }, "EUR").text),
    ).toBe("Solde de clôture rapproché ✓ — écart de -26,50 € expliqué par 2 lignes du compte à classer");
  });
  it("an unexplained gap is an error; a CSV has no balance", () => {
    expect(
      bankCheckText({ ...base, unposted_minor: "0", unposted_lines: 0, difference_minor: "3850" }, "EUR").tone,
    ).toBe("error");
    expect(bankCheckText(null, "EUR").text).toContain("CSV");
  });
});

describe("messages", () => {
  it("words the warnings", () => {
    expect(warningText({ code: "overlap", statements: 2 }, "EUR")).toContain("2 relevés déjà importés");
    expect(plain(warningText({ code: "opening_differs", expected_minor: "21150", actual_minor: "25000" }, "EUR"))).toBe(
      "Relevé manquant ? Le solde d'ouverture (250,00 €) ne suit pas le solde de clôture précédent (211,50 €).",
    );
  });
  it("words refusals in French, with the line when known, never the raw detail", () => {
    expect(importErrorText("unbalanced", "statement STMT: opening 0 + lines 1 != closing 0")).toContain(
      "ne s'équilibre pas",
    );
    expect(importErrorText("csv_row", "line 12: '12,345' has more decimals")).toMatch(/\(ligne 12\)$/);
    expect(importErrorText("something_new", "boom")).toContain("Contactez le support");
    expect(uploadErrorText("the file format does not match the bank account feed")).toContain("autre format");
    expect(uploadErrorText("not allowed")).toBe("Action non autorisée pour votre rôle.");
    expect(uploadErrorText("the file is already a statement of another bank account")).toContain(
      "autre compte bancaire",
    );
  });
  it("words the reader refusals: encoding, size, CSV profile and rows", () => {
    expect(importErrorText("csv_encoding", null)).toBe(
      "Encodage non reconnu : enregistrez l'export en CSV UTF-8 ou Windows-1252 (pas en texte Unicode/UTF-16).",
    );
    expect(importErrorText("file_too_large", "statement 1, entry 250001: more than 250000 lines")).toBe(
      "Relevé trop volumineux : exportez une période plus courte.",
    );
    expect(importErrorText("csv_profile_invalid", null)).toContain("contactez le support");
    expect(importErrorText("parse_failed", "boom")).toBe(
      "L'import a été refusé par les contrôles comptables. Contactez le support.",
    );
    const row = importErrorText("csv_row", "line 7: unclosed quote");
    expect(row).toMatch(/guillemet non fermé/);
    expect(row).toMatch(/en-tête/);
    expect(row).toMatch(/colonne Crédit/);
    expect(row).toMatch(/\(ligne 7\)$/);
  });
  it("words the review refusals: an entry split another way, the same money on another account", () => {
    expect(importErrorText("entry_detail_differs", "line 3 is part of a bank entry imported earlier")).toMatch(
      /niveau de détail.*\(ligne 3\)$/,
    );
    expect(importErrorText("imported_on_other_account", "line 2 was imported for another bank account")).toMatch(
      /autre compte bancaire.*\(ligne 2\)$/,
    );
  });
  it("offers the right files and masks third-party IBANs", () => {
    expect(acceptFor("camt053")).toBe(".xml");
    expect(acceptFor("csv")).toBe(".csv,.txt");
    expect(maskedIban("FR7630004000031234567890143")).toBe("IBAN …0143");
    expect(maskedIban(null)).toBe("");
  });
});

describe("line filters (review #15: direction counts)", () => {
  // every (direction, kind) the table allows (bank_transaction_kind)
  const allowed = [
    ...["debtor_credit", "return", "psp_payout", "batch_unsplit", "suspected_duplicate"].map((kind) => ({
      direction: "credit",
      kind,
    })),
    ...["return", "refund_out", "other_debit", "batch_unsplit", "suspected_duplicate"].map((kind) => ({
      direction: "debit",
      kind,
    })),
  ];
  const booked = (l: { direction: string; kind: string }) =>
    l.direction === "credit" && ["debtor_credit", "batch_unsplit"].includes(l.kind);

  it("« Encaissements » are exactly the lines booked as payments; the others are to classify or held", () => {
    for (const line of allowed) {
      const shown = ["encaissements", "a-classer", "doublons"].filter((k) => lineInFilter(k, line));
      expect(shown, JSON.stringify(line)).toHaveLength(1);
      expect(lineInFilter("encaissements", line)).toBe(booked(line));
      expect(lineInFilter("a-classer", line)).toBe(!booked(line) && line.kind !== "suspected_duplicate");
      expect(lineInFilter("toutes", line)).toBe(true);
    }
  });
  it("an unsplit debit batch is to classify, not a receipt", () => {
    expect(lineInFilter("a-classer", { direction: "debit", kind: "batch_unsplit" })).toBe(true);
    expect(lineInFilter("encaissements", { direction: "debit", kind: "batch_unsplit" })).toBe(false);
    expect(lineState({ kind: "batch_unsplit", direction: "debit", has_payment: false }).kind).toBe(
      "Débit groupé non ventilé",
    );
  });
  it("gives PostgREST the same rule", () => {
    expect(lineFilterOr("toutes")).toBeNull();
    expect(lineFilterOr("encaissements")).toBe("and(direction.eq.credit,kind.in.(debtor_credit,batch_unsplit))");
    expect(lineFilterOr("a-classer")).toBe(
      "kind.in.(return,refund_out,other_debit,psp_payout),and(direction.eq.debit,kind.in.(batch_unsplit))",
    );
    expect(lineFilterOr("doublons")).toBe("kind.in.(suspected_duplicate)");
    expect(Object.keys(LINE_FILTERS)).toEqual(["toutes", "encaissements", "a-classer", "doublons"]);
  });
});

describe("statement list (review #17: paging and filters)", () => {
  const account = "80000000-0000-0000-0000-000000000001";
  it("reads the page, account and status from the URL, ignoring anything else", () => {
    expect(statementListQuery({})).toEqual({ page: 1, compte: null, statut: "tous" });
    expect(statementListQuery({ page: "3", compte: account, statut: "refuses" })).toEqual({
      page: 3,
      compte: account,
      statut: "refuses",
    });
    expect(statementListQuery({ page: "-2", compte: "x' or 1=1", statut: "nimporte" })).toEqual({
      page: 1,
      compte: null,
      statut: "tous",
    });
    expect(statementListQuery({ page: ["2", "4"] }).page).toBe(1);
    expect(STATEMENT_STATUS_FILTERS.refuses.statuses).toEqual(["rejected", "failed"]);
  });
  it("links pages without repeating defaults", () => {
    expect(statementListHref({ page: 1, compte: null, statut: "tous" })).toBe("/backoffice/encaissements");
    expect(statementListHref({ page: 1, compte: account, statut: "refuses" }, 2)).toBe(
      `/backoffice/encaissements?compte=${account}&statut=refuses&page=2`,
    );
  });
});
