import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { money } from "@/lib/payments/statements";
import {
  type Entry,
  type PaymentDetail,
  REALLOCATE_TEXT,
  allocationErrorCode,
  allocationRows,
  componentLabel,
  groupsOfFour,
  itemBalances,
  liveAllocations,
  paymentActions,
  paymentStatus,
  proposalSummary,
} from "./allocation";

function entry(id: string, type: string, account: string | null, lines: [string, string, string][], reversedBy: string | null = null): Entry {
  return {
    entry_id: id,
    entry_type: type,
    effective_date: "2026-10-12",
    posted_at: "2026-10-12T10:00:00Z",
    reason: null,
    account_id: account,
    external_ref: account ? `M-${account}` : null,
    reverses_entry_id: null,
    reversed_by: reversedBy,
    amount_minor: lines.reduce((s, l) => s + BigInt(l[2]), BigInt(0)).toString(),
    lines: lines.map(([item, component, amount]) => ({
      claim_item_id: item,
      item_ref: item.toUpperCase(),
      item_kind: "invoice",
      due_date: "2026-08-20",
      component,
      amount_minor: amount,
    })),
  };
}

function detail(p: Partial<PaymentDetail["payment"]>, position: [string, string], extra: Partial<PaymentDetail> = {}): PaymentDetail {
  return {
    payment: {
      id: "p",
      amount_minor: "200000",
      currency: "EUR",
      booking_date: "2026-10-12",
      value_date: null,
      payer_name: null,
      payer_iban_end: null,
      remittance_text: null,
      creditor_reference: null,
      end_to_end_id: null,
      status: "matched",
      review_reason: null,
      account_id: "a",
      match_method: "rf_structured",
      matched_at: null,
      designation: null,
      instruction: null,
      channel: "camt053",
      method: "sct",
      ...p,
    },
    position: { allocated_minor: position[0], unallocated_minor: position[1], returned_minor: "0" },
    file: {
      account_id: "a",
      external_ref: "M-0042",
      status: "in_collection",
      client_organization_id: "c",
      client_name: "Martin SAS",
      currency: "EUR",
      legal_regime: "commercial_b2b",
      debtor_name: null,
    },
    matches: [],
    entries: [],
    notifications: [],
    documents: [],
    other_files: [],
    ...extra,
  };
}

describe("payment page", () => {
  it("names the payment states in French", () => {
    expect(paymentStatus("allocated")).toEqual({ label: "Imputé", tone: "ok" });
    expect(paymentStatus("partially_allocated").label).toBe("Imputé en partie");
    expect(paymentStatus("other")).toEqual({ label: "other", tone: "neutral" });
    expect(componentLabel("accrued_interest")).toBe("Intérêts échus");
  });

  it("lists the allocation per item and component from the live entries only, exactly", () => {
    const entries = [
      entry("e1", "allocation", "a", [["f103", "principal", "40000"], ["f101", "principal", "130000"]]),
      entry("e2", "allocation", "a", [["f102", "principal", "30000"]], "r2"),
      entry("e3", "allocation", "b", [["f101", "principal", "9007199254740993"]]),
    ];
    const rows = allocationRows(entries);
    expect(rows.map((r) => [r.line.item_ref, r.minor.toString()])).toEqual([
      ["F103", "40000"],
      ["F101", "9007199254870993"], // summed as BigInt: beyond a JS number's precision
    ]);
    const live = liveAllocations(entries);
    expect([...live.keys()]).toEqual(["a", "b"]);
    expect(live.get("a")?.map((e) => e.entry_id)).toEqual(["e1"]);
  });

  it("offers only the actions the payment's state allows", () => {
    const allocated = detail({ status: "allocated" }, ["200000", "0"], {
      entries: [entry("e1", "allocation", "a", [["f1", "principal", "200000"]])],
    });
    expect(paymentActions(allocated)).toEqual({
      reverse: true,
      allocate: false,
      releaseHold: false,
      forward: false,
      otherFile: false,
      unassign: false,
    });
    const reversed = detail({ status: "matched", review_reason: "allocation_reversed" }, ["0", "200000"]);
    expect(paymentActions(reversed)).toMatchObject({ reverse: false, allocate: true, unassign: true, forward: false });
    const held = detail({ review_reason: "hold_blocks_allocation" }, ["0", "200000"]);
    expect(paymentActions(held)).toMatchObject({ releaseHold: true, allocate: false });
    const recalled = detail({ review_reason: "account_closed" }, ["0", "200000"]);
    recalled.file!.status = "closed_recalled";
    expect(paymentActions(recalled).forward).toBe(true);
    const over = detail({ status: "partially_allocated", review_reason: "overpayment" }, ["512000", "8000"], {
      other_files: [{ account_id: "b", external_ref: "M-0043" }],
    });
    // an overpayment is never forwarded to the client (founder #8); another file of the debtor, on request
    expect(paymentActions(over)).toMatchObject({ forward: false, otherFile: true });
    expect(paymentActions({ ...over, other_files: [] }).otherFile).toBe(false);
    expect(REALLOCATE_TEXT.before_servicing_start).toContain("date d'arrêté");
  });

  it("maps the commands' errors to French messages", () => {
    expect(allocationErrorCode("the allocation changed: reload the page")).toBe("allocation_changed");
    expect(allocationErrorCode("the payment changed: reload the page")).toBe("payment_changed");
    expect(allocationErrorCode("the payment is not held: reload the page")).toBe("payment_changed");
    expect(allocationErrorCode("the amount changed: reload the page")).toBe("amount_changed");
    expect(allocationErrorCode("the proposal changed: reload the page")).toBe("proposal_changed");
    expect(allocationErrorCode("the judge's authorisation is required, filed on this file")).toBe("authorisation_required");
    expect(allocationErrorCode("the debtor's written request is required, filed on one of the two files")).toBe(
      "request_required",
    );
    expect(allocationErrorCode("the other file is not a file of the same debtor")).toBe("not_same_debtor");
    expect(allocationErrorCode("only a payment nothing was allocated from can be forwarded")).toBe("not_forwardable");
    expect(allocationErrorCode("canceling statement due to lock timeout")).toBe("allocation_busy");
    expect(allocationErrorCode("not allowed")).toBe("not_allowed");
    expect(allocationErrorCode("boom")).toBe("unknown");
    expect(errorText("allocation_busy")).toContain("réessayez");
  });
});

describe("file page", () => {
  it("groups balances per item and totals them as BigInt", () => {
    const { items, total } = itemBalances([
      { claim_item_id: "l", item_ref: "PRET-9", kind: "loan_principal", due_date: null, component: "accrued_interest", balance_minor: "12000" },
      { claim_item_id: "l", item_ref: "PRET-9", kind: "loan_principal", due_date: null, component: "principal", balance_minor: "500000" },
      { claim_item_id: "c", item_ref: "AV-105", kind: "credit_note", due_date: null, component: "principal", balance_minor: "-20000" },
    ]);
    expect(items.map((i) => [i.ref, i.total.toString(), i.components.length])).toEqual([
      ["PRET-9", "512000", 2],
      ["AV-105", "-20000", 1],
    ]);
    expect(total.toString()).toBe("492000");
  });

  it("says what applying a credit note books", () => {
    const text = proposalSummary(
      {
        credit_item_id: "c",
        credit_ref: "AV-105",
        netting_date: "2026-09-30",
        proposal_key: "k",
        amount_minor: "20000",
        targets: [{ item_id: "f", item_ref: "F-101", amount_minor: "20000" }],
      },
      (m) => money(m, "EUR"),
      (d) => d.split("-").reverse().join("/"),
    );
    const eur = money("20000", "EUR"); // French grouping and spacing as the formatter writes them
    expect(text).toBe(
      `L'avoir AV-105 réglera F-101 pour ${eur} (${eur} au total), à la date du 30/09/2026, où les deux étaient exigibles.`,
    );
    expect(groupsOfFour("RF60482193057612")).toBe("RF60 4821 9305 7612");
  });
});
