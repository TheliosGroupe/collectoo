import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import {
  REASON_CATEGORIES,
  creditNoteErrorCode,
  creditNoteText,
  effectLines,
  percent,
  refusalText,
  vatSplitText,
} from "./credit-notes";

const PREVIEW = {
  refusal: null,
  vat_rate: "0.2000",
  ht: "10000",
  vat: "2000",
  ttc: "12000",
  vat_pending: "2000",
  vat_collected: "0",
  applied: "12000",
  excess: "0",
  open_before: "54000",
  open_after: "42000",
  remaining_ht: "45000",
  remaining_after: "35000",
  allocations: [
    { account_id: "a", tier_key: "tout", ht: "6667" },
    { account_id: "b", tier_key: "tout", ht: "3333" },
  ],
};

describe("the effect sheet (M2c-5b)", () => {
  it("states the database's amounts, never one it computed", () => {
    expect(effectLines(PREVIEW)).toEqual([
      { label: "Avoir HT", value: "100,00 €" },
      { label: "TVA 20 %", value: "20,00 €" },
      { label: "Avoir TTC", value: "120,00 €" },
      { label: "Déduit de ce que la facture doit", value: "120,00 €" },
      { label: "La facture devra encore (TTC)", value: "420,00 €" },
      { label: "Reste facturé après l'avoir (HT)", value: "350,00 €" },
    ]);
  });

  it("names a refund owed when the invoice was already settled", () => {
    const rows = effectLines({ ...PREVIEW, applied: "0", excess: "12000", open_after: "0" }) ?? [];
    expect(rows.map((r) => r.label)).toContain("À rembourser au client (avec un prochain reversement)");
    expect(rows.find((r) => r.label.startsWith("À rembourser"))?.value).toBe("120,00 €");
  });

  it("shows nothing for a refusal or a malformed amount", () => {
    expect(effectLines({ refusal: "in_flight" })).toBeNull();
    expect(effectLines({ ...PREVIEW, vat: "20.5" })).toBeNull();
    expect(effectLines(null)).toBeNull();
  });

  it("says where the VAT comes off: the pending VAT first", () => {
    expect(vatSplitText(PREVIEW)).toBe("TVA de l'avoir : 20,00 € sur la TVA en attente (44574).");
    expect(vatSplitText({ ...PREVIEW, vat_pending: "500", vat_collected: "1500" })).toBe(
      "TVA de l'avoir : 5,00 € sur la TVA en attente (44574), 15,00 € sur la TVA exigible (44571).",
    );
  });

  it("words a rate as French percent", () => {
    expect(percent("0.2000")).toBe("20 %");
    expect(percent("0.0550")).toBe("5,5 %");
    expect(percent("0.021")).toBe("2,1 %");
  });
});

describe("refusals and errors (M2c-5b)", () => {
  it("explains why an invoice cannot take a credit note", () => {
    expect(refusalText(null)).toBeNull();
    expect(refusalText("in_flight")).toMatch(/attendez son débit, ou annulez ce reversement/);
    expect(refusalText("nothing_left")).toMatch(/entièrement rectifiée/);
    expect(refusalText("credit_note")).toMatch(/pas par un autre avoir/);
    expect(refusalText("something_new")).toBe("Avoir impossible pour l'instant.");
  });

  it("maps the command's refusals to French, never the database's text", () => {
    const cases: [string, string][] = [
      ["credit note refused: credit_note", "Un avoir ne se rectifie pas par un autre avoir."],
      ["credit note refused: in_flight", "pas encore débité"],
      ["credit note refused: more_than_remaining", "dépasse ce qui reste facturé"],
      ["credit note refused: invoice_changed", "rechargez-la"],
      ["credit note refused: amount_required", "montant HT positif"],
      ["credit note refused: reason_code", "motif de l'avoir"],
      ["credit note refused: reason_required", "Indiquez un motif."],
      ["credit note refused: file_not_on_invoice", "Ce dossier"],
      ["not allowed", "non autorisée"],
      ["remittance run refused: allocation_busy", "réessayez dans un instant"],
      ["commission documents: the day turned during the transaction, retry", "minuit"],
    ];
    for (const [message, text] of cases) expect(errorText(creditNoteErrorCode(message))).toContain(text);
    expect(creditNoteErrorCode("syntax error at or near")).toBe("unknown");
  });

  it("offers the three categories the command accepts", () => {
    expect(REASON_CATEGORIES.map((c) => c.code)).toEqual(["terms_error", "basis_error", "billing_error"]);
  });
});

describe("the client list (M2c-5b)", () => {
  const fc1 = { number: "FC-2026-000001", issue_date: "2026-11-02" };
  it("names the invoice a credit note rectifies", () => {
    expect(
      creditNoteText(
        { kind: "credit_note", reason: "commission", designation: "Avoir rectifiant la facture FC-2026-000001 du 02/11/2026 — encaissements annulés (relevé RV-2026-000003)" },
        [fc1],
      ),
    ).toBe("rectifie la facture FC-2026-000001 du 02/11/2026");
  });

  it("adds a manual credit note's reason category, as its line states it", () => {
    expect(
      creditNoteText(
        {
          kind: "credit_note",
          reason: "manual",
          designation:
            "Avoir rectifiant la facture FC-2026-000001 du 02/11/2026 — rectification d'une erreur d'assiette (encaissement non commissionnable)",
        },
        [fc1],
      ),
    ).toBe("rectifie la facture FC-2026-000001 du 02/11/2026 · rectification d'une erreur d'assiette (encaissement non commissionnable)");
  });

  it("lists every invoice a credit note rectifies; nothing for an invoice", () => {
    expect(
      creditNoteText({ kind: "credit_note", reason: "commission", designation: null }, [fc1, { number: "FC-2026-000004", issue_date: "2026-11-16" }]),
    ).toBe("rectifie les factures FC-2026-000001 du 02/11/2026, FC-2026-000004 du 16/11/2026");
    expect(creditNoteText({ kind: "invoice", reason: "commission", designation: null }, [fc1])).toBeNull();
  });
});
