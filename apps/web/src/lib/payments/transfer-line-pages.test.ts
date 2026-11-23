// M2c-6b-2c (plan docs/design/m2c-6b-2-plan.md §4.1, §4.3, §7.3, §7.4, §8.3): the sheets of « Débits et retours » that
// book our transfer lines — the options and preview read when a sheet opens, the effect sentences worded from what
// SQL returns (amounts, P, its bound, dates), the guards' labels, the reworded notes — the run page, « Virements » and
// the client space. The page formats; it never computes an amount, a date or a legal statement.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { type ErrorCode, errorText, FILE_BOOKED_WHEN, PAYOUT_BOOKED_WHEN } from "../boarding/forms";
import { runStatusText, statementRunView } from "../remittance/documents";
import { runPayoutNotes, runStatus } from "../remittance/runs";
import { transferBookingText } from "../remittance/transfers";
import {
  DEBIT_REVIEW,
  OUR_LOT_CREDIT_NOTE,
  OUR_LOT_FOREIGN_E2E_NOTE,
  OUR_LOT_OWN_CREDIT_NOTE,
  OUR_TRANSFER_CREDIT_NOTE,
  UNSPLIT_OURS_NOTE,
  debitReviewText,
  linkDebitErrorCode,
} from "./debits";
import { money } from "./statements";
import {
  TRANSFER_LINE_ACTION,
  memberInLine,
  membersMore,
  offersTransferLineBooking,
  parseTransferLineOptions,
  parseTransferLinePreview,
  transferLineActionLabel,
  transferLineEffects,
  transferLineRefusalText,
  type TransferLineOptions,
} from "./transfer-lines";

const EUR = "EUR";
const T = "00000000-0000-0000-0000-0000000000a9";
const C = "00000000-0000-0000-0000-0000000000a1";

/** A preview part as transfer_line_parts_json returns it. */
function part(p: Record<string, unknown>) {
  return {
    n: 1,
    kind: "payout",
    transfer_id: T,
    client_id: C,
    returns_line_id: null,
    amount_minor: "164000",
    paid_minor: "0",
    advance_minor: "0",
    p_bound: null,
    late: false,
    end_to_end_id: "RMT0123456789AB",
    run_id: "00000000-0000-0000-0000-0000000000f1",
    run_number: "RV-2026-000012",
    status: "in_file",
    client_name: "MARTIN SAS",
    ...p,
  };
}
/** An options read with one proposal of these parts (its preview ok). */
function options(o: {
  cls?: string;
  direction?: string;
  kind?: string;
  amount?: string;
  action: string;
  parts: Record<string, unknown>[];
  drafts?: { run_id: string; number: string }[];
  supersedes?: { file_id: string; number: string } | null;
  charges?: string | null;
  iban?: string | null;
  date?: string;
}): TransferLineOptions {
  const parts = o.parts.map(part);
  const raw = {
    class: o.cls ?? "E",
    kind: o.kind ?? "transfer_out",
    direction: o.direction ?? "debit",
    amount_minor: o.amount ?? "164000",
    booking_date: o.date ?? "2026-11-05",
    unsplit_ours: null,
    charges_minor: o.charges ?? null,
    counterparty_iban_end: o.iban ?? null,
    proposals: [
      {
        action: o.action,
        request: parts.map((p) => ({ kind: p.kind, transfer_id: p.transfer_id, amount: p.amount_minor })),
        parts,
        preview: {
          ok: true,
          why: null,
          detail: null,
          parts,
          drafts: o.drafts ?? [],
          supersedes_file: o.supersedes ?? null,
          expected_text: "x",
        },
      },
    ],
    members: null,
    member_count: null,
    refusal: null,
    refusal_detail: null,
    pending_line_id: null,
  };
  const parsed = parseTransferLineOptions(raw);
  if (!parsed) throw new Error("unparsed");
  return parsed;
}
function effects(o: TransferLineOptions): string {
  return transferLineEffects(o, o.proposals[0], EUR).join(" ");
}

describe("the options read and its preview are parsed, every class (§3.11, §7.3)", () => {
  it("an E debit, a lot, a reference-less debit, an unsplit entry, a credit — each proposal with its parts", () => {
    for (const [cls, direction, action] of [
      ["E", "debit", "payout"],
      ["B", "debit", "lot"],
      ["N", "debit", "unplanned_payout"],
      ["O", "debit", "payout"],
      ["E0", "debit", "unplanned_sweep"],
      ["U", "debit", "detail"],
      ["E", "credit", "returned"],
    ]) {
      const o = options({ cls, direction, action, parts: [{}] });
      expect(o.class, cls).toBe(cls);
      expect(o.direction).toBe(direction);
      expect(o.proposals[0].action).toBe(action);
      expect(o.proposals[0].parts[0].amount_minor).toBe("164000");
      expect(o.proposals[0].preview.ok).toBe(true);
    }
  });
  it("a refusal with no proposal, a lot too large with its count and no members", () => {
    const o = parseTransferLineOptions({
      class: "B",
      kind: "batch_unsplit",
      direction: "debit",
      amount_minor: "500",
      booking_date: "2026-11-05",
      proposals: [],
      members: null,
      member_count: 501,
      refusal: "lot_too_large",
      refusal_detail: null,
      pending_line_id: null,
    });
    expect(o?.refusal).toBe("lot_too_large");
    expect(o?.proposals).toEqual([]);
    expect(o?.member_count).toBe(501);
  });
  it("anything that is not the read's shape is null, never a guess", () => {
    expect(parseTransferLineOptions(null)).toBeNull();
    expect(parseTransferLineOptions({ class: "E" })).toBeNull();
    expect(parseTransferLinePreview(null)).toBeNull();
    expect(parseTransferLinePreview({ ok: true })).toBeNull();
    expect(
      parseTransferLinePreview({
        ok: false,
        why: "split_changed",
        detail: null,
        parts: [],
        drafts: [],
        supersedes_file: null,
        expected_text: null,
      })?.why,
    ).toBe("split_changed");
  });
});

describe("« Comptabiliser… » is offered from the queue's cheap bookable_as, never from the options (critic CSO-4)", () => {
  it("e, b, n, u offer it; null and absent do not", () => {
    for (const b of ["e", "b", "n", "u"]) expect(offersTransferLineBooking({ bookable_as: b }), b).toBe(true);
    expect(offersTransferLineBooking({ bookable_as: null })).toBe(false);
    expect(offersTransferLineBooking({})).toBe(false);
  });
  it("the actions' labels and buttons are the plan's; an unsplit entry's says it books from the statement's detail", () => {
    expect(TRANSFER_LINE_ACTION.payout.label).toBe("Débit d'un reversement");
    expect(TRANSFER_LINE_ACTION.lot.label).toBe("Débit d'un lot de reversements");
    expect(TRANSFER_LINE_ACTION.unplanned_payout.label).toBe("Virement hors reversement");
    expect(TRANSFER_LINE_ACTION.unplanned_sweep.label).toBe("Virement au compte propre");
    expect(TRANSFER_LINE_ACTION.returned.label).toBe("Virement revenu");
    expect(TRANSFER_LINE_ACTION.detail.label).toBe("Comptabiliser d'après le détail du relevé");
    expect(TRANSFER_LINE_ACTION.payout.button).toBe("Comptabiliser le débit");
    expect(TRANSFER_LINE_ACTION.unplanned_payout.button).toBe("Comptabiliser le virement");
    expect(TRANSFER_LINE_ACTION.returned.button).toBe("Comptabiliser le retour");
    expect(transferLineActionLabel("payout", "U")).toBe("Comptabiliser d'après le détail du relevé");
    expect(transferLineActionLabel("payout", "E")).toBe("Débit d'un reversement");
  });
});

describe("the effect sentences of « Débit d'un reversement » (§7.3)", () => {
  it("the run, its client, the debit's date, the set-off and the run's new status", () => {
    const text = effects(options({ action: "payout", parts: [{ settlement_minor: "36000" }] }));
    expect(text).toContain(
      `RV-2026-000012 (MARTIN SAS) : ${money("164000", EUR)} débités le 05/11/2026 ; ses factures sont réglées par compensation (${money("36000", EUR)}) ; son virement passe à « Débité » et le reversement à « Comptabilisé ».`,
    );
  });
  it("no set-off sentence when the run set nothing off", () => {
    const text = effects(options({ action: "payout", parts: [{ settlement_minor: "0" }] }));
    expect(text).toContain(`${money("164000", EUR)} débités le 05/11/2026 ; son virement passe à « Débité » et le reversement à « Comptabilisé ».`);
    expect(text).not.toContain("compensation");
  });
  it("late: the breach is recorded, with the date the database gives", () => {
    const text = effects(
      options({ action: "payout", parts: [{ late: true, latest_execution_date: "2026-10-30" }] }),
    );
    expect(text).toContain(
      "Ce débit est postérieur à la date limite d'exécution du 30/10/2026 : le dépassement du délai est enregistré.",
    );
    expect(effects(options({ action: "payout", parts: [{}] }))).not.toContain("dépassement");
  });
  it("a fee on the same line: « frais indiqués par le relevé » when they are the statement's, else the warning (ML-10)", () => {
    const fee = { kind: "fee", transfer_id: null, client_id: null, amount_minor: "120", run_number: null };
    const stated = effects(options({ action: "payout", amount: "164120", charges: "120", parts: [{}, fee] }));
    expect(stated).toContain(
      `Frais bancaires de ${money("120", EUR)} prélevés sur la même ligne, à la charge du cabinet (frais indiqués par le relevé).`,
    );
    expect(stated).not.toContain("n'indique pas de frais");
    const unstated = effects(options({ action: "payout", amount: "164120", charges: null, parts: [{}, fee] }));
    expect(unstated).toContain(
      "Le relevé n'indique pas de frais pour cette ligne : l'écart n'est pas justifié par le relevé. Vérifiez dans la banque avant de comptabiliser.",
    );
  });
  it("the file replaced only when the preview says so (CSO2-4)", () => {
    const sentence =
      "Le fichier FT-2026-000003-1 pas encore téléchargé sera remplacé à son téléchargement : sa quote-part dépasserait alors ce qui revient au cabinet.";
    expect(
      effects(options({ action: "payout", parts: [{}], supersedes: { file_id: T, number: "FT-2026-000003-1" } })),
    ).toContain(sentence);
    expect(effects(options({ action: "payout", parts: [{}] }))).not.toContain("sera remplacé");
  });
  it("a line without our reference says only this transfer has its amount to that account", () => {
    const text = effects(options({ cls: "N", kind: "other_debit", action: "payout", parts: [{}] }));
    expect(text).toContain(
      "Cette ligne ne porte pas notre référence : seul ce virement du cabinet (en cours, ou annulé que la banque a pu exécuter) a ce montant vers ce compte. Vérifiez dans la banque avant de comptabiliser.",
    );
    expect(effects(options({ action: "payout", parts: [{}] }))).not.toContain("ne porte pas notre référence");
  });
});

describe("the effect sentences of « Virement hors reversement », worded from P and its bound (§7.3; critic L13, critic2 ML-9)", () => {
  const unplanned = (p: Record<string, unknown>) =>
    effects(options({ action: "unplanned_payout", parts: [{ kind: "unplanned_payout", status: "cancelled", ...p }] }));
  it("P = A: all of it deducted from the next run, no advance", () => {
    const text = unplanned({ paid_minor: "164000", advance_minor: "0", p_bound: "amount" });
    expect(text).toContain(
      `${money("164000", EUR)} déjà reçus par MARTIN SAS seront déduits de son prochain reversement (sommes du reversement RV-2026-000012 annulé, encore à reverser) ; avance du cabinet : ${money("0", EUR)}.`,
    );
  });
  it("0 < P < A: the rest is the servicer's advance, and why by the bound", () => {
    const items = unplanned({ paid_minor: "120000", advance_minor: "44000", p_bound: "items" });
    expect(items).toContain(
      `${money("120000", EUR)} déjà reçus par MARTIN SAS seront déduits de son prochain reversement (sommes du reversement RV-2026-000012 annulé, encore à reverser) ; avance du cabinet de ${money("44000", EUR)} pour le reste (le reste dépasse ce qui reste dû au client sur ces sommes), reprise sur les prochains reversements du client si elle est rattachée à un seul mandat qui a une clause de reprise (jamais si elle est antérieure à l'ouverture d'une procédure collective du client), sinon à récupérer (page « Avances »).`,
    );
    const queue = unplanned({ paid_minor: "120000", advance_minor: "44000", p_bound: "queue" });
    expect(queue).toContain(
      "pour le reste (les sommes en attente du client ne permettent pas d'en déduire davantage)",
    );
    expect(queue).not.toContain("dépasse ce qui reste dû");
  });
  it("P = 0: nothing deducted, all of it an advance", () => {
    const text = unplanned({ paid_minor: "0", advance_minor: "164000", p_bound: "none" });
    expect(text).toContain(
      `Rien n'est déduit du prochain reversement de MARTIN SAS ; avance du cabinet de ${money("164000", EUR)} : ce virement n'est rattaché à aucune somme en attente de ce client, reprise sur les prochains reversements du client si elle est rattachée à un seul mandat qui a une clause de reprise (jamais si elle est antérieure à l'ouverture d'une procédure collective du client), sinon à récupérer (page « Avances »).`,
    );
  });
  it("the intro names the client and the mechanism, never a legal qualification", () => {
    const text = unplanned({ paid_minor: "0", advance_minor: "164000", p_bound: "none" });
    expect(text).toContain(
      "La banque a exécuté un virement vers MARTIN SAS hors de tout reversement en cours (virement annulé exécuté quand même, second débit d'un virement, ou virement saisi à la banque). Il est comptabilisé tel quel : le client a reçu cet argent.",
    );
    expect(text).not.toMatch(/indu|répétition|faute/);
  });
  it("the draft re-prepared, by its number", () => {
    const text = effects(
      options({
        action: "unplanned_payout",
        parts: [{ kind: "unplanned_payout", paid_minor: "0", advance_minor: "164000", p_bound: "none" }],
        drafts: [{ run_id: T, number: "RV-2026-000020" }],
      }),
    );
    expect(text).toContain("Le brouillon RV-2026-000020 sera recalculé ; sa validation en cours, s'il y en a une, est interrompue.");
  });
});

describe("« Virement au compte propre » (§7.3)", () => {
  const sweep = (share: string) =>
    effects(
      options({
        cls: "N",
        kind: "transfer_out",
        action: "unplanned_sweep",
        amount: "50000",
        iban: "1234",
        parts: [{ kind: "unplanned_sweep", transfer_id: null, client_id: null, amount_minor: "50000",
                  run_number: null, client_name: null, share_after_minor: share }],
      }),
    );
  it("the share on the dedicated account goes down by the amount", () => {
    const text = sweep("38000");
    expect(text).toContain(
      "Virement du compte dédié vers notre compte propre (IBAN …1234) sans ordre de Collectoo (ou exécuté après son annulation) : comptabilisé comme quote-part du cabinet virée au compte propre.",
    );
    expect(text).toContain(`La quote-part du cabinet en attente sur le compte dédié baisse de ${money("50000", EUR)}.`);
    expect(text).not.toContain("négative");
  });
  it("below zero: the servicer owes the dedicated account, a top-up is asked for", () => {
    expect(sweep("-12000")).toContain(
      `Elle devient négative (${money("-12000", EUR)}) : le cabinet doit cette somme au compte dédié ; demandez un approvisionnement depuis le compte propre.`,
    );
  });
});

describe("« Virement revenu » (§7.3; critic L3, critic2 ML-11)", () => {
  it("a payout's return: owed again, proposed in a next run, its payout account blocked", () => {
    const text = effects(
      options({
        direction: "credit",
        kind: "return",
        action: "returned",
        parts: [{ kind: "payout_returned", status: "booked", payout_iban_end: "0143", blocks_account: true }],
      }),
    );
    expect(text).toContain(
      `RV-2026-000012 : ${money("164000", EUR)} de nouveau dus à MARTIN SAS, proposés dans un prochain reversement avec la date limite de leurs encaissements ; son compte de reversement (IBAN …0143) est bloqué jusqu'à son remplacement ou sa reconfirmation.`,
    );
  });
  it("the block is said only when the return blocks the account (L3)", () => {
    const text = effects(
      options({ direction: "credit", kind: "return", action: "returned",
                parts: [{ kind: "payout_returned", status: "booked", blocks_account: false }] }),
    );
    expect(text).not.toContain("bloqué");
  });
  it("a sweep's return comes back to the dedicated account", () => {
    const text = effects(
      options({ direction: "credit", kind: "own_transfer_in", action: "returned", amount: "50000",
                parts: [{ kind: "sweep_returned", amount_minor: "50000", run_number: null, client_name: null }] }),
    );
    expect(text).toContain(
      `La quote-part de ${money("50000", EUR)} revient sur le compte dédié : elle sera virée de nouveau au compte propre.`,
    );
  });
  it("an unplanned payout's return: the advance cancelled, P owed again, the account blocked", () => {
    const text = effects(
      options({
        direction: "credit",
        kind: "return",
        action: "returned",
        parts: [{ kind: "unplanned_payout_returned", paid_minor: "120000", advance_minor: "44000",
                  returns_on: "2026-11-05", payout_iban_end: "0143", blocks_account: true }],
      }),
    );
    expect(text).toContain(
      `Le virement hors reversement du 05/11/2026 (${money("164000", EUR)}) revient : l'avance du cabinet de ${money("44000", EUR)} est annulée et ${money("120000", EUR)} sont de nouveau dus à MARTIN SAS ; son compte de reversement (IBAN …0143) est bloqué jusqu'à son remplacement ou sa reconfirmation.`,
    );
    const zero = effects(
      options({
        direction: "credit",
        kind: "return",
        action: "returned",
        parts: [{ kind: "unplanned_payout_returned", paid_minor: "0", advance_minor: "164000",
                  returns_on: "2026-11-05", blocks_account: false }],
      }),
    );
    expect(zero).toContain(
      `Le virement hors reversement du 05/11/2026 (${money("164000", EUR)}) revient : l'avance du cabinet de ${money("164000", EUR)} est annulée ; rien n'est de nouveau dû à MARTIN SAS.`,
    );
  });
  it("a flagged return without our reference says where it came from (ML-11)", () => {
    const text = effects(
      options({
        cls: "N",
        direction: "credit",
        kind: "return",
        action: "returned",
        parts: [{ kind: "unplanned_payout_returned", paid_minor: "0", advance_minor: "164000", returns_on: "2026-11-05" }],
      }),
    );
    expect(text).toContain(
      `La banque signale ce crédit comme un retour, sans notre référence, depuis le compte vers lequel le virement hors reversement du 05/11/2026 (${money("164000", EUR)}) est parti : il est comptabilisé comme son retour. Vérifiez dans la banque avant de comptabiliser.`,
    );
  });
  it("a fee deducted by the bank from a flagged return", () => {
    const fee = { kind: "fee", transfer_id: null, client_id: null, amount_minor: "120", run_number: null };
    const text = effects(
      options({ direction: "credit", kind: "return", action: "returned", amount: "163880", charges: "120",
                parts: [{ kind: "payout_returned", status: "booked" }, fee] }),
    );
    expect(text).toContain(`Frais de la banque déduits du retour : ${money("120", EUR)}, à la charge du cabinet (frais indiqués par le relevé).`);
  });
});

describe("a lot's members and the refusals with their run (§7.3; critic F6, critic2 ML-4, CSO2-3)", () => {
  it("each member says what this line does of it", () => {
    const debit = { direction: "debit", decided: true };
    expect(memberInLine({ transfer_id: T, in_proposal: true }, [{ kind: "payout", transfer_id: T }], debit)).toBe("débit");
    expect(
      memberInLine({ transfer_id: T, in_proposal: true }, [{ kind: "unplanned_payout", transfer_id: T }], debit),
    ).toBe("second débit, hors reversement");
    expect(memberInLine({ transfer_id: T, in_proposal: false }, [], debit)).toBe("non débité par cette ligne");
  });
  it("at most 50 members listed, the rest counted", () => {
    expect(membersMore({ members: new Array(50).fill({}), member_count: 120 })).toBe("… et 70 autres");
    expect(membersMore({ members: new Array(3).fill({}), member_count: 3 })).toBeNull();
    expect(membersMore({ members: null, member_count: 501 })).toBeNull();
  });
  it("client_run_cancellable and run_still_live name the run", () => {
    expect(transferLineRefusalText("client_run_cancellable", "RV-2026-000009")).toContain("(reversement RV-2026-000009)");
    expect(transferLineRefusalText("client_run_cancellable", "RV-2026-000009")).toContain(
      "faites d'abord annuler ce reversement par un administrateur",
    );
    expect(transferLineRefusalText("run_still_live", "RV-2026-000009")).toContain("(reversement RV-2026-000009)");
    expect(transferLineRefusalText("amount_differs", null)).toBe("Le montant ne correspond pas à celui du virement.");
  });
  it("lot_too_large says « ce lot ou cette écriture » and to tell support", () => {
    expect(transferLineRefusalText("lot_too_large", null)).toContain("Ce lot ou cette écriture compte trop de virements");
  });
  it("S06's refusals say the transfer was never handed out and to tell support (critic L15)", () => {
    for (const code of ["not_handed_out", "payout_not_handed_out_matches"]) {
      const text = transferLineRefusalText(code, null);
      expect(text, code).toContain("jamais été remis à la banque");
      expect(text, code).toContain("prévenez le support");
    }
  });
});

describe("the guards of « Lier » (§4.1; critic L8)", () => {
  it("each refusal has its label, by the kind asked for", () => {
    for (const kind of ["fee", "explained", "refund"]) {
      expect(linkDebitErrorCode("debit link refused: payout_candidate", kind)).toBe("payout_candidate");
      expect(linkDebitErrorCode("debit link refused: client_payout_line", kind)).toBe("client_payout_line");
    }
    expect(linkDebitErrorCode("debit link refused: own_transfer_out_line", "explained")).toBe("own_transfer_out_line");
    // (review 6b-2c round 3) also a payout returned or cancelled the bank may have executed, never « en cours » alone
    expect(errorText("payout_candidate")).toBe(
      "Cette ligne a le montant d'un virement du cabinet (reversement, quote-part ou remboursement en cours, ou reversement annulé ou revenu que la banque a pu exécuter) et ne porte pas sa référence : elle ne se classe pas sans comptabiliser. Si c'est ce virement, comptabilisez-la avec « Comptabiliser… » ; sinon, demandez le détail à la banque.",
    );
    expect(errorText("client_payout_line")).toBe(
      "Ce débit va vers un compte de reversement d'un client : il se comptabilise comme « Virement hors reversement » (ou comme le débit de son reversement en cours).",
    );
    expect(errorText("own_transfer_out_line")).toBe(
      "Un virement vers notre compte propre se comptabilise (« Virement au compte propre »), il ne se classe pas sans comptabiliser.",
    );
  });
  it("payout_candidate no longer promises a debit that may never come (L8)", () => {
    expect(errorText("payout_candidate")).not.toMatch(/attend(ez)? (son|le) débit|viendra/);
  });
  it("the queue's two new reasons have their labels", () => {
    // (review 6b-2c round 3) with a candidate in flight; only ended payouts: PAYOUT_AMOUNT_MATCH_ENDED
    expect(DEBIT_REVIEW.payout_amount_match).toBe(
      "Débit sans notre référence du montant d'un virement du cabinet en cours (ou d'un reversement annulé ou revenu que la banque a pu exécuter) : s'il s'agit de ce virement, comptabilisez-le comme son débit avec « Comptabiliser… ».",
    );
    expect(DEBIT_REVIEW.client_payout_iban).toBe(
      "Débit vers le compte de reversement d'un client, sans référence du cabinet : virement hors reversement (ou débit d'un reversement en cours sans sa référence).",
    );
  });
});

describe("the texts reworded now that the screen exists (§4.3): each old wording is gone", () => {
  it("PAYOUT_BOOKED_WHEN and FILE_BOOKED_WHEN name « Débits et retours » and the action", () => {
    expect(PAYOUT_BOOKED_WHEN).toBe(
      "automatiquement à l'import quand la ligne porte sa référence RMT ou celle de son lot ; sinon l'équipe la comptabilise dans « Débits et retours » (« Débit d'un reversement »)",
    );
    expect(FILE_BOOKED_WHEN).toContain("sinon l'équipe la comptabilise dans « Débits et retours » (« Débit d'un reversement », « Débit de la quote-part du cabinet »)");
    for (const t of [PAYOUT_BOOKED_WHEN, FILE_BOOKED_WHEN]) expect(t).not.toContain("à venir");
  });
  it("own_transfer_line and own_credit_own_transfer_line: by the team in « Débits et retours », else the bank's detail", () => {
    for (const [code, pronoun] of [
      ["own_transfer_line", "elle"],
      ["own_credit_own_transfer_line", "il"],
    ]) {
      const text = errorText(code as ErrorCode);
      expect(text, code).toContain("par l'équipe dans « Débits et retours »");
      expect(text, code).toContain(`sinon ${pronoun} attend le détail de la banque`);
      expect(text, code).not.toContain("écran à venir");
    }
  });
  it("the credit and lot notes say « Virement revenu »", () => {
    expect(OUR_TRANSFER_CREDIT_NOTE).toBe(
      "Crédit portant la référence de l'un de nos virements (reversement ou quote-part du cabinet) : c'est ce virement qui revient, sans que la banque l'ait signalé comme un retour. Comptabilisez-le avec « Virement revenu » pour son montant exact (s'il est inférieur, demandez le détail à la banque) ; il ne devient ni le paiement d'un débiteur ni un approvisionnement.",
    );
    for (const note of [OUR_LOT_CREDIT_NOTE, OUR_LOT_FOREIGN_E2E_NOTE, OUR_LOT_OWN_CREDIT_NOTE]) {
      expect(note).toContain(
        "« Virement revenu » propose les virements du lot dont les montants font seuls celui de la ligne ; sinon, demandez à la banque le détail du retour et prévenez le support.",
      );
      expect(note).not.toContain("écran à venir");
    }
  });
  it("UNSPLIT_OURS_NOTE offers « Comptabiliser d'après le détail du relevé »", () => {
    expect(UNSPLIT_OURS_NOTE).toContain(
      "son montant est celui de toute l'écriture, rien n'est comptabilisé automatiquement. Si le relevé détaille nos virements dans cette écriture et qu'ils en font exactement le montant, ou s'il n'y détaille que l'un de nos virements et que les frais qu'il indique pour l'écriture font la différence, « Comptabiliser d'après le détail du relevé » les propose ; sinon (le paiement d'un débiteur, un remboursement ou un approvisionnement dans l'écriture, des frais que le relevé n'indique pas, ou un détail incomplet), elle ne peut pas être comptabilisée ici : demandez le détail à la banque et prévenez le support.",
    );
    expect(UNSPLIT_OURS_NOTE).not.toContain("écran à venir");
  });
  it("review 6b-2d round 1 (pages-e2e-1): the unsplit note and the sheet's intro never refuse the charges the statement records (S08)", () => {
    // the command books one detail of ours plus the statement's charges for the entry (fee part): the texts say so
    expect(UNSPLIT_OURS_NOTE).not.toMatch(/sinon \(le paiement d'un débiteur, des frais,/);
    expect(UNSPLIT_OURS_NOTE).toContain("les frais qu'il indique pour l'écriture font la différence");
    expect(UNSPLIT_OURS_NOTE).toContain("des frais que le relevé n'indique pas");
    expect(TRANSFER_LINE_ACTION.detail.intro).toBe(
      "La banque a regroupé plusieurs opérations dans cette écriture. Le relevé détaille nos virements qu'elle contient : s'ils en font exactement le montant, ou si l'écriture ne détaille que l'un de nos virements et que les frais indiqués par le relevé font la différence, ils sont comptabilisés chacun (débit ou retour), avec ces frais.",
    );
  });
  it("review 6b-2d round 1 (pages-e2e-4): a payout's effect names each status as its page shows it", () => {
    const text = effects(options({ action: "payout", parts: [{ settlement_minor: "0" }] }));
    expect(text).toContain("son virement passe à « Débité » et le reversement à « Comptabilisé »");
    expect(text).not.toContain("le reversement passe à « Débité »");
  });
  it("the debit reviews name the action that books them", () => {
    expect(DEBIT_REVIEW.transfer_debited_twice).toContain(
      "la banque l'a peut-être exécuté deux fois. Vérifiez avec la banque, puis comptabilisez ce second débit comme « Virement hors reversement ».",
    );
    expect(DEBIT_REVIEW.batch_partial).toBe(
      "Lot débité pour un autre montant que ses virements en cours (un virement manque, a été rejeté, ou un virement déjà débité l'a été de nouveau) : « Débit d'un lot » le comptabilise si une seule combinaison de ses virements fait ce montant ; sinon, demandez le détail à la banque.",
    );
    expect(DEBIT_REVIEW.transfer_differs).toContain(
      "si la banque a prélevé ses frais sur la même ligne, comptabilisez-la comme « Débit d'un reversement » et frais ; sinon, vérifiez dans la banque.",
    );
    // (review 6b-2c pages-4) a sweep in flight of its amount is booked as that sweep's debit: transfer-line-review-fixes
    expect(DEBIT_REVIEW.own_transfer_out).toContain("« Virement au compte propre »");
    expect(DEBIT_REVIEW.return_debit_pending).toContain(
      "Comptabilisez d'abord ce débit (« Virement hors reversement ») ; ce retour se comptabilisera ensuite avec « Virement revenu ».",
    );
  });
  it("unplanned_payout_return says « Virement revenu », 2a's « prévenez le support » gone (CSO2-14)", () => {
    expect(DEBIT_REVIEW.unplanned_payout_return).toBe(
      "Retour d'un virement du cabinet (reversement ou quote-part) qui a aussi été exécuté hors de son ordre (virement annulé exécuté quand même, ou exécuté deux fois) : rien n'est comptabilisé automatiquement. Comptabilisez-le avec « Virement revenu » : c'est le retour du virement exécuté hors ordre.",
    );
    expect(DEBIT_REVIEW.unplanned_payout_return).not.toContain("prévenez le support");
  });
  it("cancelled_transfer_debited is worded by its run's status (ML-4)", () => {
    const line = { direction: "debit", kind: "transfer_out", end_to_end_id: "RMT0123456789AB",
                   original_end_to_end_id: null, review_reason: "cancelled_transfer_debited" };
    const cancelled = debitReviewText({ ...line, candidates: [{ transfer_id: T, run_status: "cancelled" }] });
    // M2c-6b-3a-2 (T14, T13; ADR-0014 « M2c-6b-3a-2 », R3): the screen books a cancelled payout's late debit — as its
    // run's payout while the run is in flight (the late predecessor), else as « Virement hors reversement »
    expect(cancelled).toContain(
      "Rien n'est comptabilisé : vérifiez dans la banque, puis comptabilisez-le avec « Comptabiliser… » : comme le débit de son reversement s'il est encore en cours, sinon comme « Virement hors reversement » (risque de double paiement).",
    );
    for (const s of ["approved", "sent"]) {
      const live = debitReviewText({ ...line, candidates: [{ transfer_id: T, run_status: s }] });
      expect(live, s).toContain(
        "Son reversement est toujours en cours : si ce débit est bien ce virement (vérifiez-le auprès de la banque quand la ligne ne porte pas sa référence), comptabilisez-le avec « Comptabiliser… » comme « Débit d'un reversement » : le reversement est comptabilisé comme payé.",
      );
      expect(live, s).not.toContain("Virement hors reversement");
    }
  });
  it("no « écran à venir » is left in lib/**", () => {
    const root = join(__dirname, "..");
    const files: string[] = [];
    const walk = (d: string) => {
      for (const f of readdirSync(d)) {
        const p = join(d, f);
        if (statSync(p).isDirectory()) walk(p);
        else if (/\.tsx?$/.test(f) && !/\.test\.tsx?$/.test(f)) files.push(p);
      }
    };
    walk(root);
    expect(files.length).toBeGreaterThan(10);
    for (const f of files) expect(readFileSync(f, "utf8"), f).not.toContain("écran à venir");
  });
});

describe("the run page (§7.4; critic CSO-6)", () => {
  const payout = {
    transfers: [{ id: T, status: "booked", end_to_end_id: "RMT0123456789AB", amount_minor: "164000",
                  debited_on: "2026-11-03", returned_on: null, line_id: T }],
    payout_account_blocked: true,
    settled_on: "2026-11-03",
    settlement_minor: "36000",
    commission_minor: "36000",
    advances_recovered_minor: "0",
    advances: [],
    unplanned: [],
    draft_unplanned: [],
  };
  it("debited, and the commission set off, with their dates", () => {
    const notes = runPayoutNotes(payout, EUR);
    expect(notes).toContain("Débité de notre compte le 03/11/2026");
    expect(notes).toContain(`Commission réglée par compensation le 03/11/2026 : ${money("36000", EUR)}`);
  });
  it("invoices and advances set off when Da > 0", () => {
    const notes = runPayoutNotes({ ...payout, advances_recovered_minor: "5000", settlement_minor: "41000" }, EUR);
    expect(notes).toContain(
      `Factures et avances réglées par compensation le 03/11/2026 : commission ${money("36000", EUR)}, avances du cabinet ${money("5000", EUR)}`,
    );
  });
  it("an overrun advance, a returned payout, an unplanned booking, a draft netting unplanned items", () => {
    const notes = runPayoutNotes(
      {
        ...payout,
        transfers: [{ ...payout.transfers[0], status: "returned", returned_on: "2026-11-05" }],
        advances: [
          { cause: "payout_overrun", amount_minor: "5000", open_minor: "5000", created_on: "2026-11-03",
            recovery: "request", clause_ref: null },
        ],
        unplanned: [{ line_id: T, kind: "unplanned_payout", amount_minor: "164000", on: "2026-11-06",
                      paid_minor: "0", advance_minor: "164000", after_cancellation: false }],
      },
      EUR,
    );
    expect(notes).toContain(
      // M2c-7a (plan §3.7 [critic] L19 (b)): worded by its cause, with the date it was recorded; M2c-7b (plan §4.3): and
      // how it is recovered
      `Avance du cabinet enregistrée le 03/11/2026 (reversement débité au-delà de ce qui restait dû) : ${money("5000", EUR)}, à récupérer par une demande de remboursement (pas de clause de reprise)`,
    );
    expect(notes).toContain(
      `Virement revenu impayé le 05/11/2026 : ${money("164000", EUR)} de nouveau dus au client, proposés dans un prochain reversement ; son compte de reversement est bloqué jusqu'à son remplacement ou sa reconfirmation.`,
    );
    expect(notes).toContain(
      `La banque a exécuté le virement de ce reversement une seconde fois le 06/11/2026 (${money("164000", EUR)}) : comptabilisé hors reversement, avance du cabinet de ${money("164000", EUR)}.`,
    );
    // the block said only while the payout account is blocked; the run that paid it again once booked
    const unblocked = runPayoutNotes(
      {
        ...payout,
        payout_account_blocked: false,
        transfers: [{ ...payout.transfers[0], status: "returned", returned_on: "2026-11-05", repaid_by: "RV-2026-000031" }],
      },
      EUR,
    );
    expect(unblocked).toContain(
      `Virement revenu impayé le 05/11/2026 : ${money("164000", EUR)} de nouveau dus au client, proposés dans un prochain reversement.`,
    );
    expect(unblocked).toContain("Reversé à nouveau par le reversement RV-2026-000031.");
    const draft = runPayoutNotes(
      { ...payout, transfers: [], draft_unplanned: [{ amount_minor: "164000", on: "2026-11-05", line_id: T,
                                                      statement_on: "2026-11-05" }] },
      EUR,
    );
    expect(draft).toContain(
      `Ce brouillon déduit ${money("164000", EUR)} déjà reçus par le client : virement exécuté hors reversement le 05/11/2026 (relevé du 05/11/2026).`,
    );
  });
  it("executed after its cancellation", () => {
    const notes = runPayoutNotes(
      { ...payout, transfers: [], unplanned: [{ line_id: T, kind: "unplanned_payout", amount_minor: "164000",
                                                on: "2026-11-06", paid_minor: "164000", advance_minor: "0",
                                                after_cancellation: true }] },
      EUR,
    );
    expect(notes).toContain(
      `La banque a exécuté le virement de ce reversement après son annulation le 06/11/2026 (${money("164000", EUR)}) : comptabilisé hors reversement, avance du cabinet de ${money("0", EUR)}.`,
    );
  });
  it("a draft re-prepared shows « Préparation en cours », never « Préparation échouée »", () => {
    const s = runStatus({ status: "draft", job: "prepare", prepared_at: null, last_failure: null } as never);
    expect(s.label).toContain("Préparation en cours");
    expect(s.label).not.toContain("échouée");
  });
});

describe("« Virements » (§7.4)", () => {
  it("debited, returned, cancelled but executed outside its run", () => {
    expect(transferBookingText("booked", { debited_on: "2026-11-03" })).toBe("Débité le 03/11/2026");
    expect(transferBookingText("returned", { debited_on: "2026-11-03", returned_on: "2026-11-05" })).toBe(
      "Revenu impayé le 05/11/2026",
    );
    expect(transferBookingText("cancelled", { unplanned_on: "2026-11-06" })).toBe(
      "Annulé — exécuté par la banque le 06/11/2026, hors reversement",
    );
    expect(transferBookingText("cancelled", {})).toBeNull();
    expect(transferBookingText("in_file", {})).toBeNull();
  });
});

describe("the client space (§7.4; critic L6, critic2 ML-12)", () => {
  it("the debit's date, the cancelled-run texts", () => {
    expect(runStatusText("booked", "164000", "2026-11-03")).toBe("Virement débité de notre compte le 03/11/2026");
    expect(runStatusText("booked", "0", "2026-11-03")).toBe("Réglé par compensation, sans virement");
    expect(runStatusText("cancelled", "164000")).toBe("Annulé avant la remise de son virement à la banque");
    expect(runStatusText("cancelled", "164000", null, "2026-11-05")).toBe(
      "Annulé — la banque a néanmoins exécuté son virement le 05/11/2026 (voir le relevé suivant)",
    );
    expect(runStatusText("booked", "164000")).toBe("Virement débité de notre compte");
  });
  it("the statement's line view passes them on", () => {
    expect(statementRunView({ status: "booked", net_minor: "164000", booked_on: "2026-11-03" }).label).toBe(
      "Virement débité de notre compte le 03/11/2026",
    );
    expect(
      statementRunView({ status: "cancelled", net_minor: "164000" }, null, "2026-11-05").label,
    ).toBe("Annulé — la banque a néanmoins exécuté son virement le 05/11/2026 (voir le relevé suivant)");
  });
});
