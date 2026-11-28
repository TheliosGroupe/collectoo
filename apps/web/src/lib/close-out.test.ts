/**
 * M2c-7f-1 (plan docs/design/m2c-7f-plan.md §2; ADR-0014 « M2c-7f-1 »): the pages' texts the close-out makes true.
 * H2 the shortfall's help counts the sweeps in flight; H9 « Comptes bancaires » words the remit lock's refusal; H11
 * a proof already recorded; H13 the withdrawal per advance; H16 « Avances »' totals and the chip from the ledger; H21
 * the statement's summary « à l'import »; H22 the « Lier » sheet after the client's mandate's end; H23 the « Virement
 * hors reversement » sheet's claw-back sentence.
 */
import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { bankAccountErrorCode } from "@/lib/payments/bank-accounts";
import { CHECK_LABEL, checkLabel } from "@/lib/payments/debits";
import { type QueueAccount, gatingOutcome, outcomeText } from "@/lib/payments/matching";
import { bankCheckText } from "@/lib/payments/statements";
import { NOT_YET_RECOVERED } from "@/lib/payments/transfer-lines";
import { advanceChip, parseAdvanceTotals } from "@/lib/remittance/advances";
import {
  advancesParam,
  parseWithdrawal,
  withdrawEffect,
  withdrawnAdvancesParam,
} from "@/lib/remittance/requests";
import { clientPaymentRefusal, clientRefundRefusal } from "@/lib/remittance/settlements";

describe("H2: « Approvisionnement du compte dédié à demander »", () => {
  it("says the sweeps in flight count, as the hourly order does", () => {
    const help = CHECK_LABEL.servicer_shortfall.help;
    expect(help).toContain("quotes-parts en cours de virement vers le compte propre");
    expect(help).toContain("au-delà des approvisionnements demandés");
    expect(checkLabel("servicer_shortfall", { noOwnAccount: true }).help).toContain(
      "quotes-parts en cours de virement vers le compte propre",
    );
  });
});

describe("H9: ops' top-up while the hourly job holds the lock", () => {
  it("is refused with a retry, never « unknown »", () => {
    for (const message of [
      "remittance run refused: allocation_busy",
      "canceling statement due to lock timeout",
      "could not obtain lock on row in relation \"bank_account\"",
    ]) {
      expect(bankAccountErrorCode(message), message).toBe("funds_busy");
    }
    expect(errorText("funds_busy")).toBe(
      "Une opération est en cours sur les fonds du cabinet : réessayez dans quelques secondes.",
    );
  });
});

describe("H11: a proof already recorded (MONEY-2)", () => {
  it("names the day it was recorded", () => {
    expect(clientPaymentRefusal("client payment refused: evidence_already_used", "2026-11-25")).toBe(
      "Ce justificatif a déjà servi à enregistrer le règlement du 25/11/2026 : ce virement est déjà enregistré. Joignez la preuve d'un autre virement.",
    );
    expect(clientPaymentRefusal("client payment refused: evidence_already_used", null)).toBe(
      "Ce justificatif a déjà servi à enregistrer un règlement : ce virement est déjà enregistré. Joignez la preuve d'un autre virement.",
    );
    expect(
      clientRefundRefusal(
        "client refund refused: evidence_already_used",
        { owed_minor: "800", currency: "EUR", kind: "client_credit" },
        "2026-11-27",
      ),
    ).toBe(
      "Ce justificatif a déjà servi à enregistrer le remboursement du 27/11/2026 de ce document : ce virement est déjà enregistré.",
    );
  });
});

describe("H13: the withdrawal per advance", () => {
  const A = { advance_id: "a", born_on: "2026-11-20", open_minor: "30000", currency: "EUR", still_requested_by: ["DRA-2026-000001"] };
  const B = { advance_id: "b", born_on: "2026-11-21", open_minor: "20000", currency: "EUR", still_requested_by: [] };
  it("names the advances that stay requested and those that may be taken back or requested anew", () => {
    expect(withdrawEffect("DRA-2026-000002", ["DRA-2026-000001"], [A, B])).toBe(
      "La demande DRA-2026-000002 est retirée. L'avance née le 20/11/2026 (300,00 €) reste demandée au client par la demande DRA-2026-000001. L'avance née le 21/11/2026 (200,00 €) pourra être reprise ou demandée de nouveau.",
    );
    expect(withdrawEffect("DRA-2026-000002", [], [B])).toBe(
      "La demande DRA-2026-000002 est retirée : l'avance née le 21/11/2026 (200,00 €) pourra être reprise ou demandée de nouveau.",
    );
    expect(withdrawEffect("DRA-2026-000002", ["DRA-2026-000001"], [A])).toBe(
      "La demande DRA-2026-000002 est retirée. L'avance née le 20/11/2026 (300,00 €) reste demandée au client par la demande DRA-2026-000001.",
    );
  });
  it("reads the command's advances and carries them in the page's address", () => {
    const parsed = parseWithdrawal({ number: "DRA-2026-000002", still_requested_by: ["DRA-2026-000001"], advances: [A, B] });
    expect(parsed?.advances).toEqual([A, B]);
    const param = advancesParam(parsed?.advances ?? []);
    expect(withdrawnAdvancesParam(param)).toEqual([
      { ...A, advance_id: "" },
      { ...B, advance_id: "" },
    ]);
    expect(withdrawnAdvancesParam("2026-13-01_1_EUR_")).toEqual([]);
    expect(withdrawnAdvancesParam(undefined)).toEqual([]);
    // the older result (no advances): the notice keeps its request-level sentence
    expect(parseWithdrawal({ number: "DRA-2026-000002", still_requested_by: [] })?.advances).toEqual([]);
  });
});

describe("H16: « Avances »' totals and the chip from the 4112 / 419 balances", () => {
  it("reads public.client_advance_totals", () => {
    const t = parseAdvanceTotals({
      advances: [{ client_id: "c1", currency: "EUR", open_minor: "50000" }],
      credits: [{ client_id: "c2", currency: "EUR", owed_minor: "2500" }],
    });
    expect(t).toEqual({
      advances: { "c1:EUR": "50000" },
      credits: { "c2:EUR": "2500" },
    });
    expect(advanceChip(t?.advances["c1:EUR"], "EUR")).toBe("Avance à récupérer 500,00 €");
    expect(parseAdvanceTotals({ advances: [{ client_id: "c1", currency: "EUR", open_minor: "5,00" }], credits: [] })).toBeNull();
    expect(parseAdvanceTotals(null)).toBeNull();
  });
});

describe("H21: the statement's summary is the import's", () => {
  it("says the lines to classify are counted at the import", () => {
    const check = { as_of: "2026-11-26", closing_minor: "10000", cash_minor: "8500", unposted_minor: "1500", unposted_lines: 2, difference_minor: "0" };
    expect(bankCheckText(check, "EUR").text).toBe(
      "Solde de clôture rapproché ✓ — écart de 15,00 € expliqué à l'import par 2 lignes du compte à classer",
    );
    expect(bankCheckText({ ...check, unposted_lines: 1 }, "EUR").text).toBe(
      "Solde de clôture rapproché ✓ — écart de 15,00 € expliqué à l'import par 1 ligne du compte à classer",
    );
  });
});

describe("H22: the « Lier » sheet after the end of the client's mandate (TUI-5)", () => {
  const file: QueueAccount = {
    account_id: "f",
    external_ref: "M-1",
    status: "in_collection",
    client_name: "Martin SAS",
    debtor_name: null,
    currency: "EUR",
    balance_minor: "80000",
    pending_minor: "0",
    rf: null,
    servicing_start: "2026-01-01",
    holds: [],
    mandate_ended_on: "2026-11-20",
  };
  it("words the hold the gate will apply, from the day the mandate ended", () => {
    expect(gatingOutcome(file, { currency: "EUR", booking_date: "2026-11-20" })).toBe("client_mandate_ended");
    expect(gatingOutcome(file, { currency: "EUR", booking_date: "2026-11-19" })).toBeNull();
    expect(gatingOutcome({ ...file, mandate_ended_on: null }, { currency: "EUR", booking_date: "2026-11-25" })).toBeNull();
    // the gate's order: an unconfirmed file first, then the end, then a closed file
    expect(gatingOutcome({ ...file, status: "staged" }, { currency: "EUR", booking_date: "2026-11-25" })).toBe("account_not_confirmed");
    expect(gatingOutcome({ ...file, status: "closed_paid" }, { currency: "EUR", booking_date: "2026-11-25" })).toBe("client_mandate_ended");
    expect(outcomeText("client_mandate_ended", file)).toBe(
      "Ce paiement sera retenu : le mandat du client a pris fin le 20/11/2026. Reversez-le au client (ou à son bénéficiaire) ou rendez-le au payeur.",
    );
  });
});

describe("H23: « Virement hors reversement »' claw-back sentence", () => {
  it("is what the plan does since 7d-2: never while a bar stands, whatever the advance's birth", () => {
    expect(NOT_YET_RECOVERED).toBe(
      "reprise sur les prochains reversements du client si elle est rattachée à un seul mandat qui a une clause de reprise (jamais tant qu'une procédure collective ou une liquidation du client est ouverte, après la fin de son mandat ou sous une saisie), sinon à récupérer (page « Avances »)",
    );
    expect(NOT_YET_RECOVERED).not.toContain("antérieure à l'ouverture");
  });
});
