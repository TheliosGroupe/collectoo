import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import {
  FILES_PAGE_SIZE,
  type InvoiceFilesRpc,
  REASON_CATEGORIES,
  creditNoteBack,
  creditNoteErrorCode,
  creditNoteFacts,
  creditNoteText,
  effectLines,
  filterFiles,
  invoiceFilesPage,
  mergeFiles,
  percent,
  reasonCategoryLabel,
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
    expect(rows.map((r) => r.label)).toContain("À rembourser au client (avec son prochain reversement, sinon par virement du cabinet)");
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
    expect(refusalText("in_flight")).toMatch(/attendez son débit avant d'émettre un avoir/);
    // review round 6: a run whose transfer is in a downloaded file can no longer be cancelled (it waits for its debit)
    expect(refusalText("in_flight")).toMatch(/une fois le fichier téléchargé, il ne peut plus l'être et attend que son débit soit lu sur le relevé/);
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

describe("review M2c-5b: the file choice beyond 200 files (tests-ui#2, F4)", () => {
  const row = (file: string, ref: string | null, key: string, open: string | number, page: string) => ({
    file_id: file,
    file_ref: ref,
    tier_key: key,
    open_minor: open,
    page_key: page,
  });

  function fakeRpc(pages: Record<string, unknown[]>, calls: Record<string, unknown>[] = []): InvoiceFilesRpc {
    return async (fn, args) => {
      calls.push({ fn, ...args });
      return { data: pages[args.p_after ?? ""] ?? [], error: null };
    };
  }

  it("asks the first page with no cursor, 200 rows at most, then the next one after the last row's key", async () => {
    const calls: Record<string, unknown>[] = [];
    const first = Array.from({ length: FILES_PAGE_SIZE }, (_, i) =>
      row(`f${i}`, `D-${String(i).padStart(4, "0")}`, "tout", "100", `k${String(i).padStart(4, "0")}`),
    );
    const rpc = fakeRpc({ "": first, k0199: [row("f200", "D-0200", "tout", "1", "k0200")] }, calls);
    const one = await invoiceFilesPage(rpc, "inv", null);
    expect(calls[0]).toEqual({ fn: "commission_invoice_files", p_invoice_id: "inv", p_limit: FILES_PAGE_SIZE });
    expect("files" in one ? one.files.length : -1).toBe(FILES_PAGE_SIZE);
    expect("next" in one ? one.next : "error").toBe("k0199");
    const two = await invoiceFilesPage(rpc, "inv", "k0199");
    expect(calls[1]).toEqual({ fn: "commission_invoice_files", p_invoice_id: "inv", p_after: "k0199", p_limit: FILES_PAGE_SIZE });
    expect(two).toEqual({ files: [{ account_id: "f200", reference: "D-0200" }], next: null });
  });

  it("lists a file once whatever its tier keys, never one with nothing left, and stops on a key that does not move", async () => {
    const rpc = fakeRpc({
      "": [row("a", "A-1", "interets", "50", "a|i"), row("a", "A-1", "tout", "10", "a|t"), row("b", "B-1", "tout", 0, "b|t")],
    });
    expect(await invoiceFilesPage(rpc, "inv", null)).toEqual({ files: [{ account_id: "a", reference: "A-1" }], next: null });
    const stuck: InvoiceFilesRpc = async () => ({
      data: Array.from({ length: FILES_PAGE_SIZE }, () => row("c", null, "tout", "5", "x")),
      error: null,
    });
    expect(await invoiceFilesPage(stuck, "inv", "x")).toEqual({ files: [{ account_id: "c", reference: null }], next: null });
  });

  it("drops a malformed row and reports a failed page", async () => {
    const rpc = fakeRpc({ "": [row("a", "A-1", "tout", "12.5", "k"), { file_id: 3 }, row("b", "B-1", "tout", 7, "k2")] });
    expect(await invoiceFilesPage(rpc, "inv", null)).toEqual({ files: [{ account_id: "b", reference: "B-1" }], next: null });
    const failing: InvoiceFilesRpc = async () => ({ data: null, error: { message: "permission denied" } });
    expect(await invoiceFilesPage(failing, "inv", null)).toEqual({ error: "permission denied" });
  });

  it("merges pages without repeating a file, in the database's order", () => {
    const a = { account_id: "a", reference: "A-1" };
    const b = { account_id: "b", reference: "B-1" };
    const c = { account_id: "c", reference: null };
    expect(mergeFiles([a, b], [b, c])).toEqual([a, b, c]);
  });

  it("finds a file by its reference, ignoring case and spaces, among the files loaded", () => {
    const files = [
      { account_id: "11111111-aaaa", reference: "M-0042" },
      { account_id: "22222222-bbbb", reference: "L-9" },
      { account_id: "33333333-cccc", reference: null },
    ];
    expect(filterFiles(files, "")).toEqual(files);
    expect(filterFiles(files, " m-00 ").map((f) => f.account_id)).toEqual(["11111111-aaaa"]);
    expect(filterFiles(files, "l9")).toEqual([]);
    expect(filterFiles(files, "3333").map((f) => f.account_id)).toEqual(["33333333-cccc"]);
  });
});

describe("review M2c-5b: a credit note's own page (tests-ui#3, F4)", () => {
  const fc1 = { id: "i1", number: "FC-2026-000001", issue_date: "2026-11-02" };
  it("goes back to the invoice it rectifies when no run issued it", () => {
    expect(creditNoteBack({ run_id: null, run_number: null }, [fc1])).toEqual({
      href: "/backoffice/reversements/factures/i1",
      label: "Facture FC-2026-000001",
    });
    expect(creditNoteBack({ run_id: "r1", run_number: "RV-2026-000003" }, [fc1])).toEqual({
      href: "/backoffice/reversements/r1",
      label: "Reversement RV-2026-000003",
    });
    expect(creditNoteBack({ run_id: null, run_number: null }, [])).toEqual({ href: "/backoffice/reversements", label: "Reversements" });
  });

  it("states a manual credit note's category in the words of the sheet", () => {
    expect(reasonCategoryLabel("basis_error")).toBe("Erreur d'assiette (encaissement non commissionnable)");
    expect(reasonCategoryLabel("something_new")).toBe("something_new");
  });

  it("reads what a credit note rectifies, and a manual one's reason, from the invoice detail", () => {
    const corrects = [{ ...fc1, ht: "-3000", vat: "-600" }];
    expect(
      creditNoteFacts({
        kind: "credit_note",
        reason: "manual",
        corrects,
        reason_code: "billing_error",
        reason_text: "taux du mandat mal saisi",
      }),
    ).toEqual({ corrected: corrects, manual: { reason_code: "billing_error", reason: "taux du mandat mal saisi" } });
    // a run's credit note: what it rectifies, no reason; an invoice: nothing; a detail without the key: nothing
    expect(creditNoteFacts({ kind: "credit_note", reason: "commission", corrects, reason_code: null, reason_text: null })).toEqual({
      corrected: corrects,
      manual: null,
    });
    expect(creditNoteFacts({ kind: "invoice", reason: "commission", corrects: [], reason_code: null, reason_text: null })).toEqual({
      corrected: [],
      manual: null,
    });
    expect(creditNoteFacts({ kind: "credit_note", reason: "manual" })).toEqual({ corrected: [], manual: null });
  });
});

describe("review M2c-5b: what the fixes refuse or owe (F1, legal#0)", () => {
  it("refuses an invoice whose own run can still be cancelled, in its own words (run_in_flight)", () => {
    expect(refusalText("run_in_flight")).toMatch(/reversement qui a émis cette facture/);
    expect(refusalText("run_in_flight")).not.toBe(refusalText("in_flight"));
    expect(creditNoteErrorCode("credit note refused: run_in_flight")).toBe("credit_note_run_in_flight");
    expect(creditNoteErrorCode("credit note refused: in_flight")).toBe("credit_note_in_flight");
    expect(errorText(creditNoteErrorCode("credit note refused: run_in_flight"))).toMatch(/reversement qui a émis cette facture/);
  });

  it("says how a refund owed is paid when no later run comes, never that it was paid (legal#0)", () => {
    const rows = effectLines({ ...PREVIEW, applied: "0", excess: "12000", open_after: "0" }) ?? [];
    const label = rows.find((r) => r.label.startsWith("À rembourser"))?.label ?? "";
    expect(label).toMatch(/prochain reversement/);
    expect(label).toMatch(/sinon par virement/);
    expect(label).not.toMatch(/remboursé|payé/);
  });
});
