import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { checkLabel } from "@/lib/payments/debits";
import { payoutSetOff } from "@/lib/payments/transfer-lines";
import { advanceRecovery, advanceStatus, clientSpaceAdvances } from "./advances";
import { refusalText } from "./requests";
import {
  TRIGGER_LABEL,
  blockerLabel,
  failureLabel,
  parseRunWithheld,
  refundNote,
  refundPaid,
  runWithheldNotes,
} from "./runs";
import { owesAdvanceNote } from "./settlements";
import { holdLabel } from "./transfers";

// M2c-7d-2 (plan docs/design/m2c-7-plan.md §6.2.6, §6.2.9, §6.2.11, §6.3, §6.4): the set-off bars and the withholding at
// the debit, as the pages word them. Every rule is SQL's; these only word it, and never present the servicer's rule as
// the law's (« règle du cabinet » where the law is not the source).

describe("the run's trigger and the seizure's block (§6.2.9, §6.2.11 (a) 8b)", () => {
  it("names a run prepared to give back a withheld set-off", () => {
    expect(TRIGGER_LABEL.settlement_withheld).toBe("Compensation retenue à rendre");
  });
  it("says a seizure bars the payouts and the set-off until its release", () => {
    expect(blockerLabel("client_status:seizure")).toBe(
      "Saisie entre les mains du cabinet : ni reversement ni compensation jusqu'à la mainlevée",
    );
    expect(failureLabel("payout_blocked:client_status:seizure")).toBe(
      "virement bloqué — Saisie entre les mains du cabinet : ni reversement ni compensation jusqu'à la mainlevée",
    );
  });
});

describe("the hold before download (§6.2.11 (b))", () => {
  it("names the client's changed status and the exit, whichever the switch", () => {
    expect(holdLabel("client_status_changed")).toBe(
      "La situation du client a changé depuis la préparation (procédure collective, liquidation, fin du mandat ou saisie) : ce reversement compense ce qui ne peut plus l'être. Annulez le reversement et préparez-en un nouveau",
    );
    expect(holdLabel("client_status_changed", true)).toBe(holdLabel("client_status_changed"));
  });
});

describe("the nightly (§6.3)", () => {
  it("words set_off_after_bar as the servicer's rule, its exit with counsel", () => {
    const l = checkLabel("set_off_after_bar");
    expect(l.label).toBe("Compensation passée après une procédure, une fin de mandat ou une saisie");
    expect(l.help).toContain("enregistré après la lecture que le débit en a faite");
    expect(l.help).toContain("règle du cabinet");
    expect(l.help).toContain("avocat");
    expect(l.help).not.toMatch(/nulle|annulée de plein droit/);
  });
  it("(review round 1, TUI-1) names the invoice bar as the code applies it: a claim born before the opening", () => {
    const l = checkLabel("set_off_after_bar");
    expect(l.help).toContain(
      "(créance née avant l'ouverture de la procédure collective du client, liquidation, fin du mandat, saisie en cours ; pour une avance, toute procédure en cours)",
    );
    expect(l.help).not.toContain("ouverte avant la naissance");
  });
  it("(review round 1, MLAW-3) says a set-off made before the mandate's end was recorded is not alerted, quoting 2008", () => {
    const l = checkLabel("set_off_after_bar");
    expect(l.help).toContain(
      "« Si le mandataire ignore la mort du mandant ou l'une des autres causes qui font cesser le mandat, ce qu'il a fait dans cette ignorance est valide » (art. 2008 C. civ.)",
    );
    // Verifier round 1 (end-bar-knowledge-date-as-law): the recording date is the firm's rule, not the article's.
    expect(l.help).toContain(
      "c'est une règle du cabinet, qui tient la date d'enregistrement pour celle où il a connu la fin (à confirmer avec l'avocat, OQ-93)",
    );
  });
  it("no longer tells ops that a seizure leaves the set-off open", () => {
    const l = checkLabel("seizure_standing");
    expect(l.help).not.toContain("ne bloque pas encore");
    expect(l.help).toContain("ni virement de reversement ni compensation");
    expect(l.help).toContain("La compensation ne préjudicie pas aux droits acquis par des tiers");
  });
});

describe("the request and the advances of a client in a proceeding (§6.2.6, L4)", () => {
  it("refuses a request while a proceeding stands, as the plan words it", () => {
    expect(refusalText("in_proceeding")).toBe(
      "Client en procédure collective : l'avance n'est ni reprise ni demandée ; elle est à déclarer.",
    );
  });
  it("says what happens to an advance whatever its birth (no longer « née avant » only)", () => {
    const r = { recovery: "barred_proceeding" as const, clause_ref: null, in_flight_run: null };
    expect(advanceRecovery(r)).toBe("Pas de reprise ni de demande : client en procédure collective ; avance à déclarer");
    expect(
      advanceStatus({
        ...r,
        reversed: false,
        open_minor: "5000",
        amount_minor: "5000",
        recovered: { compensation: "0", payment_own: "0", payment_dedicated: "0", write_off: "0" },
        currency: "EUR",
      } as Parameters<typeof advanceStatus>[0]),
    ).toBe("non reprise sur les reversements du client ni demandée (client en procédure collective : avance à déclarer)");
    const s = clientSpaceAdvances({
      rows: [
        {
          advance_id: "a",
          cause: "remitted_reversal",
          born_on: "2026-11-12",
          open_minor: "5000",
          currency: "EUR",
          recovery: "barred_proceeding",
          clause_ref: null,
        },
      ],
      total: [{ currency: "EUR", open_minor: "5000" }],
    } as Parameters<typeof clientSpaceAdvances>[0]);
    expect(s.heading).toBe("Avances du cabinet : 50,00 €");
    expect(s.lines[0]).toContain(
      "votre procédure collective étant en cours, elle n'est ni déduite de vos reversements ni réclamée",
    );
  });
  it("words « Ce que le client doit au cabinet »'s advance the client may not pay", () => {
    expect(owesAdvanceNote({ before_opening: true, payable: false })).toBe(
      "Créance antérieure à l'ouverture de la procédure du client",
    );
    expect(owesAdvanceNote({ before_opening: false, payable: false })).toBe(
      "Client en procédure collective : avance ni reprise ni demandée, à déclarer",
    );
    expect(owesAdvanceNote({ before_opening: false, payable: true })).toBeNull();
  });
});

describe("the run page's withheld set-off (§6.2.11 (a))", () => {
  const w = {
    withheld_minor: "30000",
    commission_minor: "20000",
    advances_minor: "10000",
    refund_unpaid_minor: "0",
    withheld_on: "2026-11-24",
    reason: "Compensation retenue : procédure collective depuis le 19/11/2026 (règle du cabinet)",
    set_off_commission_minor: "36000",
    set_off_advances_minor: "0",
    given_back_by: "RV-2026-000008",
    giving_back_by: null,
  };
  it("parses the read (amounts as minor units in text)", () => {
    expect(parseRunWithheld(w)).toEqual(w);
    expect(parseRunWithheld({ ...w, withheld_minor: 30000 })).toBeNull();
    expect(parseRunWithheld(null)).toBeNull();
  });
  it("says what was withheld, why, and that it goes back to the client", () => {
    expect(runWithheldNotes(parseRunWithheld(w)!, "EUR")).toEqual([
      "Compensation retenue au débit le 24/11/2026 : 300,00 € (factures 200,00 €, avances du cabinet 100,00 €) — procédure collective depuis le 19/11/2026 (règle du cabinet) ; rendue au client par le reversement RV-2026-000008",
      "Réglé par compensation au débit : commission 360,00 €",
    ]);
    expect(runWithheldNotes(parseRunWithheld({ ...w, given_back_by: null })!, "EUR")[0]).toContain(
      "à rendre au client par le prochain reversement",
    );
  });
  it("(review round 1, MLAW-4, TUI-3) says « rendue » only once the giving run is booked", () => {
    const inFlight = parseRunWithheld({ ...w, given_back_by: null, giving_back_by: "RV-2026-000009" })!;
    const note = runWithheldNotes(inFlight, "EUR")[0];
    expect(note).toContain("à rendre au client par le reversement RV-2026-000009 (validé, virement en cours)");
    expect(note).not.toContain("rendue au client");
  });
  it("(review round 1, TUI-2) a withheld plan's refund not paid: listed, never said refunded", () => {
    // 046b sw2 (iii): FC r3 30 000 and r2 5 000 withheld, the credit note's 12 000 refund not paid; W = 23 000
    const r = parseRunWithheld({
      ...w,
      withheld_minor: "23000",
      commission_minor: "35000",
      advances_minor: "0",
      refund_unpaid_minor: "12000",
      set_off_commission_minor: "0",
      given_back_by: null,
    })!;
    expect(runWithheldNotes(r, "EUR")).toEqual([
      "Compensation retenue au débit le 24/11/2026 : 230,00 € (factures 350,00 €, moins le remboursement d'avoir non versé 120,00 € qui reste dû au client) — procédure collective depuis le 19/11/2026 (règle du cabinet) ; à rendre au client par le prochain reversement",
    ]);
    const card = { status: "booked", refund_minor: "12000", currency: "EUR" };
    expect(refundPaid(card, r)).toBe("0");
    expect(refundNote({ ...card, refund_minor: refundPaid(card, r) })).toBeNull();
    expect(refundNote({ ...card, refund_minor: refundPaid(card, null) })).toBe("avoir remboursé 120,00 €");
    expect(parseRunWithheld({ ...w, refund_unpaid_minor: undefined })).toBeNull();
  });
});

describe("(review round 1, MLAW-2) the « Lier » preview of a payout's debit", () => {
  const m = (x: string | null | undefined) => `${x}¤`;
  it("says what the booking sets off and what it withholds, from the database's split", () => {
    expect(payoutSetOff({ settlement_minor: "36000", withheld_minor: "30000" }, m)).toBe(
      " ; ses factures sont réglées par compensation (36000¤) ; 30000¤ de compensation retenus (règle du cabinet : la situation du client ne la permet plus), rendus au client par son prochain reversement",
    );
    expect(payoutSetOff({ settlement_minor: "0", withheld_minor: "20000" }, m)).toBe(
      " ; 20000¤ de compensation retenus (règle du cabinet : la situation du client ne la permet plus), rendus au client par son prochain reversement",
    );
    expect(payoutSetOff({ settlement_minor: "20000", withheld_minor: "0" }, m)).toBe(
      " ; ses factures sont réglées par compensation (20000¤)",
    );
    expect(payoutSetOff({ settlement_minor: null, withheld_minor: null }, m)).toBe("");
  });
});

describe("the pages' texts made true (§6.4)", () => {
  const page = (p: string) => readFileSync(join(__dirname, "../../app", p), "utf8");
  it("the events' note says a seizure bars the set-off too", () => {
    const s = page("backoffice/clients/[id]/reversement/client-events-section.tsx");
    expect(s).not.toContain("pas encore bloquées");
    expect(s).toContain("ni reversement ni compensation");
  });
  it("the run page names the withheld line", () => {
    expect(page("backoffice/reversements/[id]/page.tsx")).toContain(
      'settlement_withheld: "Compensation retenue au débit, rendue"',
    );
  });
  it("the client's page lists what is not set off, as the servicer's rule", () => {
    const s = page("backoffice/clients/[id]/reversement/page.tsx");
    expect(s).toContain("ni en liquidation, ni pendant une saisie");
    expect(s).toContain("règle du cabinet");
  });
});
