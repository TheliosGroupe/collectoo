import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { CHECK_LABEL } from "@/lib/payments/debits";
import { TRANSFER_LINE_REFUSAL, transferLineErrorCode, transferLineErrorText } from "@/lib/payments/transfer-lines";
import { clientSpaceAdvances, requestLabel } from "./advances";
import { REMITTANCE_KINDS } from "./remittance-file";
import {
  owesRequestCandidates,
  parseClientRepaymentRequests,
  parseRepaymentPreview,
  parseWithdrawal,
  repaymentRefusal,
  requestLetterNote,
  requestedOn,
  requestSheetEffect,
  spaceRequestLine,
  withdrawEffect,
  withdrawSheetText,
} from "./requests";
import { NO_DESIGNATION, type OpenDocuments, designationSentence, parsePaymentPreview } from "./settlements";

// M2c-7c-2 (plan docs/design/m2c-7-plan.md §5.5): « Demander le remboursement » on « Avances » and « Ce que le client
// doit au cabinet », « Retirer la demande », the column « Demandé le », the client space's requests. Every amount and
// date is SQL's (text); these only word them.

const NBSP = " ";
const NNBSP = " ";
const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";

const REQUEST = {
  request_id: "33333333-3333-4333-8333-333333333333",
  number: "DRA-2026-000001",
  issue_date: "2026-11-25",
  currency: "EUR",
  total_minor: "200000",
  withdrawn_on: null,
  document_id: "44444444-4444-4444-8444-444444444444",
  advance_ids: [A],
};

describe("the reads", () => {
  it("parses the client's requests, and refuses another shape (never a guess)", () => {
    expect(parseClientRepaymentRequests({ rows: [REQUEST] })?.rows).toEqual([REQUEST]);
    expect(parseClientRepaymentRequests({ rows: [{ ...REQUEST, total_minor: 2000 }] })).toBeNull();
    expect(parseClientRepaymentRequests({ rows: [{ ...REQUEST, issue_date: "25/11/2026" }] })).toBeNull();
    expect(parseClientRepaymentRequests({ rows: [{ ...REQUEST, advance_ids: "x" }] })).toBeNull();
    expect(parseClientRepaymentRequests(null)).toBeNull();
    // (review round 1, MONEY-LAW-2, TUI-3) a letter addressed to the person who acts for the client
    expect(parseClientRepaymentRequests({ rows: [{ ...REQUEST, to_representative: true }] })?.rows).toEqual([
      { ...REQUEST, to_representative: true },
    ]);
    expect(parseClientRepaymentRequests({ rows: [{ ...REQUEST, to_representative: false }] })?.rows).toEqual([REQUEST]);
    expect(parseClientRepaymentRequests({ rows: [{ ...REQUEST, to_representative: "yes" }] })).toBeNull();
  });
  it("parses the preview: the total from SQL, each advance's refusal", () => {
    const p = parseRepaymentPreview({
      total_minor: "40000",
      refusal: null,
      detail: null,
      rows: [
        { advance_id: A, open_minor: "30000", refusal: null, detail: null },
        { advance_id: B, open_minor: "10000", refusal: "recently_requested", detail: "2026-11-20" },
      ],
    });
    expect(p?.total_minor).toBe("40000");
    expect(p?.rows[1].refusal).toBe("recently_requested");
    expect(parseRepaymentPreview({ total_minor: 40000, rows: [] })).toBeNull();
  });
});

describe("the sheets' texts", () => {
  it("names each advance by its birth and origin, the file's reference as it is", () => {
    expect(requestLabel({ born_on: "2026-11-23", cause: "remitted_reversal", file_ref: "C2929" })).toBe(
      "Avance née le 23/11/2026 (paiement repris après reversement (dossier C2929))",
    );
    expect(requestLabel({ born_on: "2026-11-23", cause: "double_payout", file_ref: null })).toBe(
      "Avance née le 23/11/2026 (virement hors reversement)",
    );
  });
  it("says what the request does: a letter in the client space, to print for the post; nothing is moved", () => {
    expect(requestSheetEffect("200000", "EUR")).toBe(
      `Une demande de remboursement de 2${NNBSP}000,00${NBSP}€ est adressée au client. La lettre est déposée dans l'espace du client ; imprimez-la pour un envoi postal.`,
    );
    expect(withdrawEffect("DRA-2026-000001")).toBe(
      "La demande DRA-2026-000001 est retirée : l'avance pourra être reprise ou demandée de nouveau.",
    );
  });
  it("words « Demandé le » from the request SQL names", () => {
    expect(requestedOn({ request_id: REQUEST.request_id, number: "DRA-2026-000001", issue_date: "2026-11-25" })).toBe(
      "Demandé le 25/11/2026 (DRA-2026-000001)",
    );
    expect(requestedOn(null)).toBeNull();
  });
});

describe("the refusals, in French per code", () => {
  const r = (code: string, detail?: string) => repaymentRefusal(`repayment request refused: ${code}`, detail);
  it("names the run, the day, the clause the refusal carries", () => {
    expect(r("in_flight", "RV-2026-000007")).toBe("Déjà réglé par le reversement RV-2026-000007 en cours : attendez son débit.");
    expect(r("recently_requested", "2026-11-20")).toBe(
      "Une demande a déjà été adressée pour cette avance le 20/11/2026 : une relance est possible 30 jours après.",
    );
    expect(r("clawback_applies", "art. 7.4")).toBe(
      "Cette avance est reprise sur les prochains reversements du client (art. 7.4 du mandat) : une demande la ferait payer deux fois.",
    );
  });
  it("payout_not_received names the payout that came back: the run's own, or one outside any run", () => {
    expect(r("payout_not_received", "RV-2026-000001:run")).toBe(
      "Le reversement RV-2026-000001 est revenu et n'a pas encore été versé de nouveau : le client n'a pas reçu cette somme.",
    );
    expect(r("payout_not_received", "RV-2026-000003:unplanned")).toBe(
      "Le virement hors reversement qui avait payé cet encaissement (relevé RV-2026-000003) est revenu et n'a pas encore été versé de nouveau : le client n'a pas reçu cette somme.",
    );
  });
  it("words every other code, and never reads another command's refusal as one of these", () => {
    expect(r("not_open")).toBe("Cette avance n'a plus rien à régler : rechargez la page.");
    expect(r("total_changed")).toBe("Les montants ont changé depuis l'affichage : rechargez la page.");
    expect(r("identity_incomplete")).toBe("L'identité de facturation du cabinet est incomplète (Paramètres › Facturation).");
    expect(r("no_own_account")).toBe("Aucun compte propre n'est enregistré (Paramètres › Facturation).");
    expect(r("before_opening")).toBe(
      "Avance née avant l'ouverture de la procédure collective du client : le client ne peut pas la payer, aucune demande ne lui est adressée.",
    );
    // M2c-7d-1 (plan §6.4; ADR-0014 « M2c-7d-1 », house rule R3): who acts for the client can now be recorded; (review
    // round 1, TUI-6; R3) an old « Tutelle ou curatelle » row is qualified first, the heirs named too
    expect(r("recipient_unknown")).toBe(
      "Indiquez d'abord qui agit pour le client (notaire ou héritiers, tuteur, curateur ou liquidateur ; une « Tutelle ou curatelle » enregistrée avant leur distinction se précise d'abord) : la lettre lui est adressée, ou en copie au curateur.",
    );
    expect(r("already_withdrawn")).toBe("Cette demande est déjà retirée.");
    expect(r("reason_required")).toBe("Indiquez le motif du retrait.");
    expect(r("bad_request")).toBe("La demande est incomplète : rechargez la page.");
    expect(repaymentRefusal("not allowed")).toMatch(/administrateurs et responsables des opérations/);
    expect(repaymentRefusal("client payment refused: not_open")).toMatch(/n'a pas pu être adressée/);
  });
});

describe("the client space", () => {
  it("lists each request with its date and total, and a withdrawal", () => {
    expect(spaceRequestLine(REQUEST)).toBe(
      `Demande de remboursement d'avances DRA-2026-000001 du 25/11/2026 : 2${NNBSP}000,00${NBSP}€`,
    );
    expect(spaceRequestLine({ ...REQUEST, withdrawn_on: "2026-11-26" })).toBe(
      `Demande de remboursement d'avances DRA-2026-000001 du 25/11/2026 : 2${NNBSP}000,00${NBSP}€ — demande retirée le 26/11/2026`,
    );
  });
  it("an advance requested says so; withdrawn, it says a request may come again", () => {
    const space = {
      rows: [
        {
          advance_id: A,
          currency: "EUR",
          cause: "remitted_reversal" as const,
          created_on: "2026-11-20",
          born_on: "2026-11-20",
          open_minor: "200000",
          recovery: "request" as const,
          clause_ref: null,
        },
      ],
      total: [{ currency: "EUR", open_minor: "200000" }],
    };
    expect(clientSpaceAdvances(space, [REQUEST]).lines).toEqual([
      `Avance née le 20/11/2026 (paiement repris après reversement) : 2${NNBSP}000,00${NBSP}€ — demande de remboursement DRA-2026-000001 adressée le 25/11/2026.`,
    ]);
    expect(clientSpaceAdvances(space, [{ ...REQUEST, withdrawn_on: "2026-11-26" }]).lines).toEqual([
      `Avance née le 20/11/2026 (paiement repris après reversement) : 2${NNBSP}000,00${NBSP}€ — une demande de remboursement pourra vous être adressée.`,
    ]);
    // the same as 7b without requests
    expect(clientSpaceAdvances(space).lines).toEqual(clientSpaceAdvances(space, []).lines);
  });
  it("the client's route serves the request's PDF (its kind among the remittance documents)", () => {
    expect(REMITTANCE_KINDS.has("advance_repayment_request_pdf")).toBe(true);
  });
});

describe("the nightly", () => {
  it("words the alert of a letter not drawn one hour after its request", () => {
    expect(CHECK_LABEL.repayment_request_document_missing.label).toBe("Lettre de demande de remboursement non produite");
    expect(CHECK_LABEL.repayment_request_document_missing.help).toContain("il y a plus d'une heure");
  });
});

describe("LEX-28 and the letter's words", () => {
  it("never words a request « abandon » nor « remise »", () => {
    const src = readFileSync(join(__dirname, "requests.ts"), "utf-8");
    expect(src).not.toMatch(/abandon|remise/i);
  });
});

// ---------------------------------------------------------------------------------------------------------------------
// Review fixes round 1 (ADR-0014 « M2c-7c-2 review fixes »)
// ---------------------------------------------------------------------------------------------------------------------

describe("(review round 1, MONEY-1) a return that would release a requested advance", () => {
  it("is refused advance_requested, the page saying to withdraw the request first", () => {
    const code = transferLineErrorCode({ code: "55000", message: "transfer line booking refused: advance_requested" });
    expect(code).toBe("advance_requested");
    const text = transferLineErrorText(code);
    expect(text).toBe(TRANSFER_LINE_REFUSAL.advance_requested);
    expect(text).toContain("demande de remboursement");
    expect(text).toContain("« Retirer la demande »");
    expect(text).not.toMatch(/prévenez le support/);
  });
});

describe("(review round 1, UI-1) « Retirer la demande » says what still asks for the advance", () => {
  it("before: true whatever other request names its advances", () => {
    expect(withdrawSheetText("DRA-2026-000002")).toBe(
      "La demande DRA-2026-000002 est retirée : l'espace du client l'indique. Ses avances pourront être reprises ou demandées de nouveau, sauf celles qu'une autre demande en cours nomme encore.",
    );
  });
  it("after: the request that still names them (a reminder withdrawn), or none", () => {
    expect(withdrawEffect("DRA-2026-000002", ["DRA-2026-000001"])).toBe(
      "La demande DRA-2026-000002 est retirée. La demande DRA-2026-000001 nomme encore ses avances : elles restent demandées au client.",
    );
    expect(withdrawEffect("DRA-2026-000002", ["DRA-2026-000001", "DRA-2026-000003"])).toBe(
      "La demande DRA-2026-000002 est retirée. Les demandes DRA-2026-000001, DRA-2026-000003 nomment encore ses avances : elles restent demandées au client.",
    );
    expect(withdrawEffect("DRA-2026-000002", [])).toBe(withdrawEffect("DRA-2026-000002"));
  });
  it("reads still_requested_by from the withdrawal's result (never a guess)", () => {
    expect(
      parseWithdrawal({
        request_id: REQUEST.request_id,
        number: "DRA-2026-000002",
        withdrawn_on: "2026-11-26",
        still_requested_by: ["DRA-2026-000001"],
      }),
      // M2c-7f-1 (H13, R3): and the advances, per advance (none in this older result)
    ).toEqual({ number: "DRA-2026-000002", still_requested_by: ["DRA-2026-000001"], advances: [] });
    expect(parseWithdrawal({ number: "DRA-2026-000002", still_requested_by: "DRA-2026-000001" })).toBeNull();
    expect(parseWithdrawal({ number: "DRA-2026-000002", still_requested_by: ["not a number"] })).toBeNull();
    expect(parseWithdrawal(null)).toBeNull();
  });
});

describe("(review round 1, TUI-5) « Ce que le client doit au cabinet » offers a reminder after 30 days, as « Avances »", () => {
  const advance = (id: string) => ({
    id,
    cause: "remitted_reversal",
    created_on: "2026-10-01",
    born_on: "2026-10-01",
    amount_minor: "30000",
    open_minor: "30000",
    mandate_reference: "MAND-a8",
    recovery: "request",
    clause_ref: null,
    before_opening: false,
    payable: true,
    in_flight_run: null,
  });
  const live = (issue: string, ids: string[]) => ({ ...REQUEST, issue_date: issue, withdrawn_on: null, advance_ids: ids });
  it("an advance requested less than 30 days ago is not offered; 30 days after, it is — « Relancer »", () => {
    expect(owesRequestCandidates([advance(A)], [live("2026-10-27", [A])], "EUR", "2026-11-25")).toEqual({
      candidates: [],
      label: null,
    });
    const after = owesRequestCandidates([advance(A)], [live("2026-10-26", [A])], "EUR", "2026-11-25");
    expect(after.candidates.map((c) => c.advance_id)).toEqual([A]);
    expect(after.label).toBe("Relancer");
  });
  it("never requested: « Demander le remboursement »; a withdrawn request does not count", () => {
    expect(owesRequestCandidates([advance(A), advance(B)], [live("2026-10-26", [A])], "EUR", "2026-11-25").label).toBe(
      "Demander le remboursement",
    );
    expect(
      owesRequestCandidates([advance(A)], [{ ...live("2026-11-20", [A]), withdrawn_on: "2026-11-21" }], "EUR", "2026-11-25")
        .label,
    ).toBe("Demander le remboursement");
  });
  it("in flight, under a clause or before the client's proceeding: never offered", () => {
    const run = { run_id: B, number: "RV-2026-000001" };
    expect(owesRequestCandidates([{ ...advance(A), in_flight_run: run }], [], "EUR", "2026-11-25").candidates).toEqual([]);
    expect(owesRequestCandidates([{ ...advance(A), recovery: "clawback" }], [], "EUR", "2026-11-25").candidates).toEqual([]);
    expect(owesRequestCandidates([{ ...advance(A), before_opening: true }], [], "EUR", "2026-11-25").candidates).toEqual([]);
  });
});

describe("(review round 1, TUI-4, NIGHT-1) a request withdrawn before its letter was drawn", () => {
  it("offers no letter: the client space says nothing more, the staff page says why there is none", () => {
    const undrawn = { ...REQUEST, document_id: null };
    expect(requestLetterNote(undrawn, "client")).toBe("Lettre en préparation.");
    expect(requestLetterNote(undrawn, "staff")).toBe("Lettre en préparation.");
    expect(requestLetterNote({ ...undrawn, withdrawn_on: "2026-11-26" }, "client")).toBeNull();
    expect(requestLetterNote({ ...undrawn, withdrawn_on: "2026-11-26" }, "staff")).toBe(
      "Lettre non produite : la demande a été retirée avant.",
    );
    expect(requestLetterNote(REQUEST, "client")).toBeNull();
    expect(requestLetterNote({ ...REQUEST, withdrawn_on: "2026-11-26" }, "client")).toBeNull();
  });
  it("(review round 1, MONEY-LAW-2, TUI-3) a letter to the person who acts for the client is not shown to the client", () => {
    const toRep = { ...REQUEST, document_id: null, to_representative: true };
    expect(requestLetterNote(toRep, "client")).toBe(
      "Lettre adressée à la personne qui agit pour le client : elle n'est pas affichée ici.",
    );
    expect(requestLetterNote({ ...toRep, withdrawn_on: "2026-11-26" }, "client")).toBeNull();
    expect(requestLetterNote({ ...REQUEST, to_representative: true }, "staff")).toBeNull();
  });
  it("the nightly's help says what happens to a letter not drawn, and what ops do", () => {
    const help = CHECK_LABEL.repayment_request_document_missing.help;
    expect(help).not.toContain("réessayée automatiquement");
    expect(help).toContain("quelques fois");
    expect(help).toContain("« Retirer la demande »");
    expect(help).toContain("adressez-en une nouvelle");
  });
});

describe("(review round 1, MONEY-2) a dedicated-account line whose label names a DRA-…", () => {
  const docs = {
    client_id: "55555555-5555-4555-8555-555555555555",
    currency: "EUR",
    today: "2026-11-25",
    procedure: false,
    own_account: true,
    invoices: [],
    advances: [
      {
        id: A,
        cause: "remitted_reversal",
        created_on: "2026-11-22",
        born_on: "2026-11-22",
        amount_minor: "30000",
        open_minor: "30000",
        mandate_reference: "MAND-a8",
        recovery: "request",
        clause_ref: null,
        before_opening: false,
        payable: true,
        in_flight_run: null,
      },
    ],
    written_off: [],
    refunds_owed: [],
    credits: [],
    default_order: [],
    default_open_minor: "30000",
  } satisfies OpenDocuments;
  const p = parsePaymentPreview({
    amount_minor: "30000",
    open_minor: "30000",
    credit_minor: "0",
    refusal: null,
    rows: [{ ord: 1, document_kind: "advance", document_id: A, number: null, amount_minor: "30000", vat_moved_minor: "0", cause: null }],
  });
  it("names the advance by its day and its request", () => {
    expect(designationSentence([A], p, docs, [{ number: "DRA-2026-000019", advance_ids: [A] }])).toBe(
      "Le libellé désigne l'avance du 22/11/2026 (demande DRA-2026-000019) : le règlement lui est imputé.",
    );
  });
  it("says nothing is designated in words that cover both kinds", () => {
    expect(NO_DESIGNATION).toBe(
      "Le libellé ne désigne aucune facture ni demande de remboursement : ordre par défaut (factures échues, avances, autres factures).",
    );
  });
});
