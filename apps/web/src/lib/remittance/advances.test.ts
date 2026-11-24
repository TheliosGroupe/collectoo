import { describe, expect, it } from "vitest";
import { CHECK_LABEL } from "@/lib/payments/debits";
import { type RemittedEntry, parseAllocationRemitted, reverseRemittedEffect } from "@/lib/payments/remitted";
import { TRANSFER_LINE_REFUSAL } from "@/lib/payments/transfer-lines";
import {
  type AdvanceRow,
  advanceChip,
  advanceDates,
  advanceOrigin,
  advanceRecovered,
  advanceRecovery,
  advanceStatus,
  clientSpaceAdvances,
  parseClientAdvances,
  parseClientSpaceAdvances,
  writeOffEffect,
  writeOffRefusal,
  writeOffRefusalOf,
} from "./advances";
import { type RunPayout, runPayoutNotes } from "./runs";

// M2c-7b (plan docs/design/m2c-7-plan.md §4.3): the « Avances » page, the write-off sheet, the client space, the chip,
// the run page note and the texts made true. Every amount and date comes from SQL as text; these only word them.

const row: AdvanceRow = {
  advance_id: "a1",
  client_id: "c1",
  client_name: "Martin SAS",
  currency: "EUR",
  cause: "remitted_reversal",
  created_on: "2026-11-12",
  // (review round 2) born before it was recorded: its entry's date (a payout debited earlier, a statement imported late)
  born_on: "2026-11-10",
  cause_on: "2026-11-12",
  file_ref: "M-0042",
  amount_minor: "200000",
  recovered: { compensation: "0", payment_own: "0", payment_dedicated: "0", write_off: "0" },
  open_minor: "200000",
  reversed: false,
  mandate_id: "m1",
  mandate_reference: "MAND-MARTIN-2026",
  recovery: "clawback",
  clause_ref: "art. 7.4",
  in_flight_run: null,
  created_at: "2026-11-12T10:00:00+00:00",
};

describe("« Avances » (4.1.7)", () => {
  it("parses the read and refuses another shape", () => {
    const r = parseClientAdvances({ rows: [row], next: null, totals: [], can_write_off: true });
    expect(r?.rows[0].open_minor).toBe("200000");
    expect(parseClientAdvances({ rows: [{ ...row, open_minor: 12 }], next: null, totals: [], can_write_off: true })).toBeNull();
    expect(parseClientAdvances({ rows: [{ ...row, recovery: "magic" }], next: null, totals: [], can_write_off: true })).toBeNull();
    expect(parseClientAdvances({ rows: [{ ...row, cause: "gift" }], next: null, totals: [], can_write_off: true })).toBeNull();
    expect(parseClientAdvances(null)).toBeNull();
    // (review round 1, M7B-MONEY-2) an advance born before the client's proceeding
    expect(
      parseClientAdvances({
        rows: [{ ...row, recovery: "barred_proceeding", clause_ref: null }],
        next: null,
        totals: [],
        can_write_off: true,
      })?.rows[0].recovery,
    ).toBe("barred_proceeding");
  });

  // (review round 2, advance-date-contradicts-barred) the advance's date is its birth (private.advance_born_on, the date
  // the barred rule reads), its recording date apart and labelled so
  it("dates an advance by its birth, its recording apart", () => {
    expect(advanceDates(row)).toEqual({ born: "10/11/2026", recorded: "enregistrée le 12/11/2026" });
    expect(advanceDates({ ...row, born_on: "2026-11-12" })).toEqual({ born: "12/11/2026", recorded: null });
    const without: Record<string, unknown> = { ...row };
    delete without.born_on;
    expect(parseClientAdvances({ rows: [without], next: null, totals: [], can_write_off: true })).toBeNull();
    expect(parseClientAdvances({ rows: [row], next: null, totals: [], can_write_off: true })?.rows[0].born_on).toBe(
      "2026-11-10",
    );
  });

  it("words each origin, with the file of a collection taken back", () => {
    expect(advanceOrigin(row)).toBe("Paiement repris après reversement (dossier M-0042)");
    expect(advanceOrigin({ ...row, file_ref: null })).toBe("Paiement repris après reversement");
    expect(advanceOrigin({ ...row, cause: "payout_overrun" })).toBe("Reversement au-delà du dû");
    expect(advanceOrigin({ ...row, cause: "double_payout" })).toBe("Virement hors reversement");
  });

  it("words each recovery mode and the run taking it back", () => {
    expect(advanceRecovery(row)).toBe("Reprise sur les prochains reversements (art. 7.4 du mandat)");
    expect(advanceRecovery({ ...row, recovery: "request", clause_ref: null })).toBe(
      "Demande de remboursement (pas de clause de reprise)",
    );
    expect(advanceRecovery({ ...row, recovery: "request_no_mandate", clause_ref: null })).toBe(
      "Demande de remboursement (avance rattachée à aucun mandat unique)",
    );
    expect(advanceRecovery({ ...row, in_flight_run: { run_id: "r3", number: "RV-2026-000003" } })).toBe(
      "Reprise par RV-2026-000003 en cours",
    );
    // (review round 1, M7B-MONEY-2) never « reprise » for an advance the prepare will not set off
    expect(advanceRecovery({ ...row, recovery: "barred_proceeding", clause_ref: null })).toBe(
      "Pas de reprise : avance née avant l'ouverture de la procédure collective du client",
    );
  });

  // (review round 1, tests-ui-3) what became of it, and what was recovered apart from what was passed as a loss
  it("says a written-off advance is settled by a loss, never « Récupérée »", () => {
    const none = { compensation: "0", payment_own: "0", payment_dedicated: "0", write_off: "0" };
    expect(advanceStatus({ ...row, open_minor: "0", recovered: { ...none, write_off: "200000" } })).toBe(
      "Soldée (passée en perte)",
    );
    expect(
      advanceStatus({ ...row, open_minor: "0", recovered: { ...none, compensation: "150000", write_off: "50000" } }),
    ).toBe("Soldée (dont 500,00 € passés en perte)");
    expect(advanceStatus({ ...row, open_minor: "0", recovered: { ...none, compensation: "200000" } })).toBe("Récupérée");
    expect(advanceStatus({ ...row, open_minor: "0", reversed: true })).toBe("Annulée avec ce qu'elle couvrait");
    expect(advanceStatus(row)).toBe("Reprise sur les prochains reversements (art. 7.4 du mandat)");
    expect(
      advanceRecovered({ recovered: { ...none, compensation: "150000", payment_own: "10000", write_off: "50000" } }),
    ).toBe("160000");
  });

  it("puts the chip on a client with an open advance only", () => {
    expect(advanceChip("200000", "EUR")).toBe("Avance à récupérer 2 000,00 €");
    expect(advanceChip("0", "EUR")).toBeNull();
    expect(advanceChip(null, "EUR")).toBeNull();
  });
});

describe("the write-off sheet (4.1.6, 4.3; founder Q5)", () => {
  it("states every effect, never a remission toward the client", () => {
    const t = writeOffEffect("50000", "EUR");
    expect(t).toBe(
      "Le cabinet enregistre une perte de 500,00 € (compte 6780). Collectoo ne réclame plus cette somme au client (ni reprise, ni demande de remboursement) ; rien ne lui est envoyé : ce n'est pas une remise de dette. Irréversible.",
    );
  });

  it("maps every refusal", () => {
    const open = { open_minor: "80000", currency: "EUR", in_flight_number: "RV-2026-000004" };
    expect(writeOffRefusal("advance write-off refused: amount_exceeds_open", open)).toBe(
      "Le montant dépasse ce qui reste à récupérer (800,00 €).",
    );
    expect(writeOffRefusal("advance write-off refused: open_changed", open)).toBe(
      "L'avance a changé depuis l'affichage : rechargez la page.",
    );
    expect(writeOffRefusal("advance write-off refused: in_flight", open)).toBe(
      "Cette avance est reprise par le reversement RV-2026-000004 en cours : attendez son débit.",
    );
    expect(writeOffRefusal("advance write-off refused: in_flight", { ...open, in_flight_number: null })).toBe(
      "Cette avance est reprise par un reversement en cours : attendez son débit.",
    );
    expect(writeOffRefusal("advance write-off refused: not_open", open)).toBe("Cette avance est déjà récupérée.");
    expect(writeOffRefusal("advance write-off refused: evidence_required", open)).toBe("Joignez la pièce justificative.");
    expect(writeOffRefusal("advance write-off refused: bad_amount", open)).toBe(
      "Montant invalide (en euros, deux décimales au plus).",
    );
    expect(writeOffRefusal("advance write-off refused: reason_required", open)).toBe("Indiquez le motif.");
    expect(writeOffRefusal("not allowed", open)).toBe(
      "Réservé aux administrateurs du cabinet (double authentification).",
    );
    expect(writeOffRefusal("advance write-off refused: bad_request", open)).toBe(
      "La demande est incomplète : rechargez la page.",
    );
  });

  // (review round 1, tests-ui-5) the sheet's mapping: the refusal's detail names the run taking the advance back
  it("names the run in flight from the refusal's detail", () => {
    const ctx = { open_minor: "80000", currency: "EUR" };
    expect(writeOffRefusalOf({ message: "advance write-off refused: in_flight", details: "RV-2026-000004" }, ctx)).toBe(
      "Cette avance est reprise par le reversement RV-2026-000004 en cours : attendez son débit.",
    );
    expect(writeOffRefusalOf({ message: "advance write-off refused: in_flight", details: null }, ctx)).toBe(
      "Cette avance est reprise par un reversement en cours : attendez son débit.",
    );
    expect(writeOffRefusalOf({ message: "advance write-off refused: in_flight", details: "n'importe quoi" }, ctx)).toBe(
      "Cette avance est reprise par un reversement en cours : attendez son débit.",
    );
    expect(writeOffRefusalOf({ message: "advance write-off refused: not_open", details: "RV-2026-000004" }, ctx)).toBe(
      "Cette avance est déjà récupérée.",
    );
  });
});

describe("the client space (4.3)", () => {
  const space = {
    rows: [
      { advance_id: "a1", currency: "EUR", cause: "remitted_reversal", created_on: "2026-11-12", born_on: "2026-11-10",
        open_minor: "200000", recovery: "clawback", clause_ref: "art. 7.4" },
      { advance_id: "a2", currency: "EUR", cause: "double_payout", created_on: "2026-11-20", born_on: "2026-11-20",
        open_minor: "5000", recovery: "request_no_mandate", clause_ref: null },
    ],
    total: [{ currency: "EUR", open_minor: "205000" }],
  };

  it("says what the client owes and how it is recovered, never « abandon » nor « remise »", () => {
    const s = parseClientSpaceAdvances(space);
    expect(s).not.toBeNull();
    const t = clientSpaceAdvances(s!);
    expect(t.heading).toBe("Avances du cabinet à rembourser : 2 050,00 €");
    expect(t.lines).toEqual([
      "Avance née le 10/11/2026 (paiement repris après reversement) : 2 000,00 € — reprise sur vos prochains reversements (art. 7.4 du mandat).",
      "Avance née le 20/11/2026 (virement hors reversement) : 50,00 € — une demande de remboursement pourra vous être adressée.",
    ]);
    for (const line of [t.heading, ...t.lines]) expect(line).not.toMatch(/abandon|remise/i);
  });

  // (review round 1, M7B-MONEY-2) never « reprise » for an advance born before the client's proceeding
  it("never promises a claw-back the prepare will not make", () => {
    const barred = {
      rows: [{ ...space.rows[0], recovery: "barred_proceeding", clause_ref: null }],
      total: [{ currency: "EUR", open_minor: "200000" }],
    };
    const t = clientSpaceAdvances(parseClientSpaceAdvances(barred)!);
    // (review round 2, advance-date-contradicts-barred) the date beside « antérieure à l'ouverture » is the advance's
    // birth (10/11, the one the rule reads), never its recording (12/11); a pre-opening claim is never said « à
    // rembourser »: the heading neutral, each line its own fact
    expect(t.heading).toBe("Avances du cabinet : 2 000,00 €");
    expect(t.lines).toEqual([
      "Avance née le 10/11/2026 (paiement repris après reversement) : 2 000,00 € — antérieure à l'ouverture de votre procédure collective, elle n'est pas déduite de vos reversements.",
    ]);
    for (const line of [t.heading, ...t.lines]) expect(line).not.toMatch(/reprise|abandon|remise|perte|rembourser/i);
    // one barred among others: the total holds it, so the heading stays neutral too
    const mixed = { rows: [barred.rows[0], space.rows[1]], total: [{ currency: "EUR", open_minor: "205000" }] };
    expect(clientSpaceAdvances(parseClientSpaceAdvances(mixed)!).heading).toBe("Avances du cabinet : 2 050,00 €");
  });

  // (M2c-7c-1 review round 3) 045 sl9: a liquidation recorded alone, an advance born before it under a mandate without a
  // claw-back clause — SQL says barred_proceeding (the client may not pay it: L641-3 al. 1), so the client space never
  // says it is to be repaid nor that a request will come, even beside the sum it paid, held for its procedure
  it("never says a pre-judgment advance of a liquidation is to be repaid", () => {
    const liquidation = {
      rows: [{ advance_id: "a9", currency: "EUR", cause: "remitted_reversal", created_on: "2026-11-24", born_on: "2026-11-22",
               open_minor: "20000", recovery: "barred_proceeding", clause_ref: null }],
      total: [{ currency: "EUR", open_minor: "20000" }],
    };
    const t = clientSpaceAdvances(parseClientSpaceAdvances(liquidation)!);
    expect(t.heading).toBe("Avances du cabinet : 200,00 €");
    expect(t.lines).toEqual([
      "Avance née le 22/11/2026 (paiement repris après reversement) : 200,00 € — antérieure à l'ouverture de votre procédure collective, elle n'est pas déduite de vos reversements.",
    ]);
    for (const line of [t.heading, ...t.lines]) expect(line).not.toMatch(/rembourser|remboursement|demande/i);
  });

  it("says nothing without an open advance, and refuses another shape", () => {
    expect(clientSpaceAdvances({ rows: [], total: [] })).toEqual({ heading: null, lines: [] });
    expect(parseClientSpaceAdvances({ rows: [{ ...space.rows[0], open_minor: 1 }], total: [] })).toBeNull();
    const unborn: Record<string, unknown> = { ...space.rows[0] };
    delete unborn.born_on;
    expect(parseClientSpaceAdvances({ rows: [unborn], total: [] })).toBeNull();
  });
});

describe("the run page note (4.3, [critic] L19 (b))", () => {
  const payout: RunPayout = {
    transfers: [],
    settled_on: null,
    settlement_minor: "0",
    commission_minor: "0",
    advances_recovered_minor: "0",
    advances: [],
    unplanned: [],
    draft_unplanned: [],
  };
  const adv = (over: Record<string, unknown>) => ({
    cause: "remitted_reversal",
    amount_minor: "200000",
    open_minor: "200000",
    created_on: "2026-11-12",
    recovery: "clawback",
    clause_ref: "art. 7.4",
    written_off_minor: "0",
    ...over,
  });

  it("words each advance by its cause and how it is recovered", () => {
    expect(runPayoutNotes({ ...payout, advances: [adv({})] }, "EUR")).toEqual([
      "Avance du cabinet enregistrée le 12/11/2026 (encaissement de ce reversement annulé ou repris) : 2 000,00 €, à reprendre sur les prochains reversements du client (clause de reprise, art. 7.4 du mandat)",
    ]);
    expect(
      runPayoutNotes({ ...payout, advances: [adv({ cause: "payout_overrun", recovery: "request", clause_ref: null })] }, "EUR"),
    ).toEqual([
      "Avance du cabinet enregistrée le 12/11/2026 (reversement débité au-delà de ce qui restait dû) : 2 000,00 €, à récupérer par une demande de remboursement (pas de clause de reprise)",
    ]);
    expect(
      runPayoutNotes(
        { ...payout, advances: [adv({ cause: "double_payout", recovery: "request_no_mandate", clause_ref: null })] },
        "EUR",
      ),
    ).toEqual([
      "Avance du cabinet enregistrée le 12/11/2026 (virement exécuté hors reversement) : 2 000,00 €, à récupérer par une demande de remboursement (avance rattachée à aucun mandat unique)",
    ]);
    expect(runPayoutNotes({ ...payout, advances: [adv({ open_minor: "0" })] }, "EUR")).toEqual([
      "Avance du cabinet enregistrée le 12/11/2026 (encaissement de ce reversement annulé ou repris) : 2 000,00 €, récupérée",
    ]);
    expect(
      runPayoutNotes({ ...payout, advances: [adv({ open_minor: "0", written_off_minor: "50000" })] }, "EUR"),
    ).toEqual([
      "Avance du cabinet enregistrée le 12/11/2026 (encaissement de ce reversement annulé ou repris) : 2 000,00 €, soldée (dont 500,00 € passés en perte)",
    ]);
    // (review round 1, M7B-MONEY-2) never « à reprendre » for an advance born before the client's proceeding
    expect(
      runPayoutNotes({ ...payout, advances: [adv({ recovery: "barred_proceeding", clause_ref: null })] }, "EUR"),
    ).toEqual([
      "Avance du cabinet enregistrée le 12/11/2026 (encaissement de ce reversement annulé ou repris) : 2 000,00 €, non reprise sur les reversements du client (avance née avant l'ouverture de sa procédure collective)",
    ]);
    // (review round 1, tests-ui-2) a cover released with what it covered, never « récupérée »
    expect(runPayoutNotes({ ...payout, advances: [adv({ reversed: true, open_minor: "0" })] }, "EUR")).toEqual([
      "Avance du cabinet enregistrée le 12/11/2026 (encaissement de ce reversement annulé ou repris) : 2 000,00 €, annulée (le virement hors reversement qui avait payé l'encaissement est revenu)",
    ]);
    // never « paiement repris par la banque » for a « Désimputer », an overrun or a double payout
    for (const c of ["remitted_reversal", "payout_overrun", "double_payout"])
      expect(runPayoutNotes({ ...payout, advances: [adv({ cause: c })] }, "EUR").join(" ")).not.toMatch(/repris par la banque/);
  });
});

describe("« Désimputer » regains how the advance is recovered ([critic] L19 (d))", () => {
  const e: RemittedEntry = {
    entry_id: "e2",
    account_id: "f42",
    run_number: "RV-2026-000001",
    run_transfer: true,
    booked_on: "2026-11-03",
    amount_minor: "200000",
    paid_on: "2026-11-03",
    paid_how: "paid",
    paid_run_number: "RV-2026-000001",
    returned_via: null,
    recovery: "clawback",
    clause_ref: "art. 7.4",
  };

  it("reads the recovery from the read, never guesses it", () => {
    expect(parseAllocationRemitted([e])).toEqual([e]);
    expect(parseAllocationRemitted([{ ...e, recovery: "magic" }])).toBeNull();
    const without: Record<string, unknown> = { ...e };
    delete without.recovery;
    expect(parseAllocationRemitted([without])).toBeNull();
    expect(parseAllocationRemitted([{ ...e, clause_ref: 7 }])).toBeNull();
  });

  it("per the advance's recovery", () => {
    // (review round 1, tests-ui-8 (a); R3) under a claw-back clause the next runs do deduct it: never « pas déduite »
    expect(reverseRemittedEffect([e], "EUR")).toBe(
      "Déjà reversé au client (reversement RV-2026-000001, débité le 03/11/2026). En désimputant, le cabinet lui en fait l'avance (2 000,00 €), qu'il reprendra sur ses prochains reversements (art. 7.4 du mandat).",
    );
    // (review round 1, M7B-MONEY-2) born before the client's proceeding: neither set off nor requested
    expect(reverseRemittedEffect([{ ...e, recovery: "barred_proceeding", clause_ref: null }], "EUR")).toBe(
      "Déjà reversé au client (reversement RV-2026-000001, débité le 03/11/2026). En désimputant, le cabinet lui en fait l'avance (2 000,00 €) : la somme n'est pas déduite de ses autres encaissements (avance antérieure à l'ouverture de la procédure collective du client).",
    );
    // two entries recovered differently: each part with its amount
    expect(
      reverseRemittedEffect(
        [e, { ...e, entry_id: "e3", amount_minor: "100000", recovery: "request", clause_ref: null }],
        "EUR",
      ),
    ).toMatch(
      /En désimputant, le cabinet lui en fait l'avance \(3 000,00 €\), dont 2 000,00 € qu'il reprendra sur ses prochains reversements \(art\. 7\.4 du mandat\) ; dont 1 000,00 € non déduits de ses autres encaissements \(une demande de remboursement pourra lui être adressée\)\.$/,
    );
    expect(parseAllocationRemitted([{ ...e, recovery: "barred_proceeding", clause_ref: null }])?.[0].recovery).toBe(
      "barred_proceeding",
    );
    expect(reverseRemittedEffect([{ ...e, recovery: "request", clause_ref: null }], "EUR")).toBe(
      "Déjà reversé au client (reversement RV-2026-000001, débité le 03/11/2026). En désimputant, le cabinet lui en fait l'avance (2 000,00 €) : la somme n'est pas déduite de ses autres encaissements. Une demande de remboursement pourra lui être adressée.",
    );
  });
});

describe("the texts made true (4.3)", () => {
  // (review round 1, tests-ui-8 (b); R3) the claw-back only of an advance on a single mandate with the clause, never of
  // one born before the client's proceeding
  const recovered =
    "Avec une clause de reprise du mandat auquel elle est rattachée, elle est déduite des prochains reversements du client ; sinon (pas de clause, aucun mandat unique, ou avance née avant l'ouverture d'une procédure collective du client), elle reste à récupérer (page « Avances »). Un administrateur peut la passer en perte.";
  it("the advance checks say how an advance is recovered", () => {
    for (const code of ["advance_open", "payout_overrun", "double_payout_open"])
      expect(CHECK_LABEL[code].help.endsWith(recovered)).toBe(true);
  });
  it("the return of an unplanned booking whose advance was recovered", () => {
    expect(TRANSFER_LINE_REFUSAL.advance_settled).toBe(
      "Cette avance a déjà été en partie récupérée : ce retour ne peut pas être comptabilisé dans Collectoo ; prévenez le support.",
    );
  });
});
