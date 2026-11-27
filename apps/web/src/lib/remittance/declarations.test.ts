import { describe, expect, it } from "vitest";
import { checkLabel, checkSubjectLink } from "@/lib/payments/debits";
import { DISPOSITION_KIND, claimsToDeclareHelp, dispositionRefusal, outcomeRefusal } from "./declarations";
import { parseRunWithheld, runWithheldNotes } from "./runs";

// M2c-7d-3 (plan docs/design/m2c-7-plan.md §6.3, §6.4; ADR-0014 « M2c-7d-3 »): the declarations' alerts, the payouts after a
// liquidation and their disposition, a withheld set-off given back after a return, as the pages word them. Every rule is
// SQL's; these only word it, quote only what the texts say (read on LibreJustice, 2026-11-25), and never present the
// servicer's rule as the law's (« règle du cabinet » where the law is not the source).

const CLIENT = "00000000-0000-0000-0000-0000000000a2";

describe("claims_to_declare (§6.3, [critic] L8, L4)", () => {
  const pre = {
    client_id: CLIENT,
    document_kind: "invoice",
    number: "FC-2026-000006",
    pre_opening: true,
    deadline: "2027-01-21",
    deadline_basis: "publication",
    opening_on: "2026-11-19",
    opening_kind: "proceeding_opened",
    publication_date: "2026-11-21",
    born_on: "2026-11-13",
    p0: false,
  };
  it("names the document, its deadline and its basis (two months after the publication, R622-24)", () => {
    const l = checkLabel("claims_to_declare", { details: pre });
    expect(l.label).toBe("Créance du cabinet à déclarer");
    expect(l.help).toContain(
      "Facture FC-2026-000006 à déclarer au mandataire judiciaire au plus tard le 21/01/2027 (deux mois après la publication du jugement au BODACC le 21/11/2026, art. R622-24 C. com.).",
    );
    expect(l.help).toContain("« deux mois à compter de la publication du jugement d'ouverture au Bulletin officiel des annonces civiles et commerciales »");
  });
  // review round 1 (ML-3): the day the two months end (CPC 641 al. 2), never « avant le » (a day stricter than the
  // article); a delay ending on a non-working day runs to the next working day (CPC 642, read on LibreJustice)
  it("states the day the delay ends, « au plus tard », and CPC 642's extension — the alert on the day unextended", () => {
    const h = checkLabel("claims_to_declare", { details: { ...pre, deadline: "2027-01-23", publication_date: "2026-11-23" } }).help;
    expect(h).toContain("à déclarer au mandataire judiciaire au plus tard le 23/01/2027");
    expect(h).not.toMatch(/avant le \d/);
    expect(h).toContain(
      "La date indiquée est le jour où expirent les deux mois (art. 641 du code de procédure civile, dont les règles s'appliquent sauf disposition contraire, art. R662-1 C. com.) ; « Le délai qui expirerait normalement un samedi, un dimanche ou un jour férié ou chômé est prorogé jusqu'au premier jour ouvrable suivant » (art. 642 du même code) : l'alerte suit la date non prorogée, règle du cabinet.",
    );
  });
  it("for a claim born after the judgment: two months after its exigibility, the advance's date (règle du cabinet)", () => {
    const l = checkLabel("claims_to_declare", {
      details: { ...pre, document_kind: "advance", number: null, pre_opening: false, deadline: "2027-01-23", deadline_basis: "exigibility", born_on: "2026-11-23" },
    });
    expect(l.help).toContain(
      "Avance du cabinet née le 23/11/2026 à déclarer au mandataire judiciaire au plus tard le 23/01/2027 (deux mois après son exigibilité, art. L622-24 C. com. : « Les délais courent à compter de la date d'exigibilité de la créance » ; l'exigibilité retenue est la date de l'avance, règle du cabinet).",
    );
  });
  it("without the publication date: asks for it, and names the liquidator in liquidation", () => {
    const l = checkLabel("claims_to_declare", {
      details: { ...pre, opening_kind: "liquidation", deadline: null, deadline_basis: "publication_missing", publication_date: null },
    });
    expect(l.help).toContain("Facture FC-2026-000006 à déclarer au liquidateur : date de publication à saisir");
    // review round 1 (TUI-1): the true path — no command adds a date to a recorded event; the event recorded again,
    // and in liquidation the liquidator's account confirmed again (046c dc3 pins both)
    expect(l.help).toContain(
      "une date ne s'ajoute pas à un événement déjà enregistré : enregistrez à nouveau le même événement sur la page du client (même date d'effet), avec la date de publication du jugement au BODACC, dont part le délai de déclaration ; le compte du liquidateur est alors à confirmer à nouveau par un second administrateur (les reversements restent bloqués jusque-là).",
    );
    expect(l.help).not.toContain("enregistrez sur la page du client la date de publication");
    // a proceeding: nothing to confirm again (the opening requires no payee)
    const proceeding = checkLabel("claims_to_declare", {
      details: { ...pre, deadline: null, deadline_basis: "publication_missing", publication_date: null },
    }).help;
    expect(proceeding).toContain("dont part le délai de déclaration. ");
    expect(proceeding).not.toContain("compte du liquidateur");
  });
  it("says what stops it and which documents it lists, as the servicer's rule", () => {
    const l = checkLabel("claims_to_declare", { details: pre });
    expect(l.help).toContain("« Créances du cabinet déclarées au mandataire judiciaire (ou au liquidateur) »");
    expect(l.help).toContain("règle du cabinet");
    expect(l.help).toContain("Prioritaire à partir de 15 jours avant la date limite.");
    expect(l.help).not.toMatch(/forclos|déchu/);
  });
  it("leads to the client's events (an advance) or the invoice", () => {
    expect(checkSubjectLink({ code: "claims_to_declare", subject_type: "client_advance", subject_id: "x", details: pre })).toBe(
      `/backoffice/clients/${CLIENT}/reversement#evenements`,
    );
    expect(checkSubjectLink({ code: "claims_to_declare", subject_type: "commission_invoice", subject_id: "inv", details: pre })).toBe(
      "/backoffice/reversements/factures/inv",
    );
  });
});

describe("post_opening_unpaid (§6.3, [critic] L8)", () => {
  it("in a proceeding: quotes L622-17 IV, computes no deadline", () => {
    const l = checkLabel("post_opening_unpaid", { details: { opening_kind: "proceeding_opened", number: "FC-2026-000008" } });
    expect(l.label).toBe("Facture née après le jugement, impayée à son échéance");
    expect(l.help).toContain(
      "« Les créances impayées perdent le privilège que leur confère le II du présent article si elles n'ont pas été portées à la connaissance de l'administrateur et, à défaut, du mandataire judiciaire ou, lorsque ces organes ont cessé leurs fonctions, du commissaire à l'exécution du plan ou du liquidateur, dans le délai d'un an à compter de la fin de la période d'observation. » (art. L622-17 IV C. com.)",
    );
    expect(l.help).toContain("Collectoo ne connaît pas la fin de la période d'observation");
  });
  it("in a liquidation: quotes L641-13 III", () => {
    const l = checkLabel("post_opening_unpaid", { details: { opening_kind: "liquidation", number: "FC-2026-000009" } });
    expect(l.help).toContain(
      "dans le délai de six mois à compter de la publication du jugement ouvrant ou prononçant la liquidation ou, à défaut, dans le délai d'un an à compter de celle du jugement arrêtant le plan de cession » (art. L641-13 III C. com.)",
    );
  });
  // review round 2: a run's own invoice netted in full has no due date of its own; once the debit withheld its set-off
  // it is unpaid from that day (private.invoice_withheld_on), the row's `withheld_on`
  it("a netted invoice whose set-off the debit withheld: unpaid from that day, named as the servicer's rule", () => {
    const l = checkLabel("post_opening_unpaid", {
      details: { opening_kind: "liquidation", number: "FC-2026-000010", due_date: null, withheld_on: "2026-11-23" },
    });
    expect(l.help).toContain(
      "La facture FC-2026-000010 est née après le jugement d'ouverture. Elle devait être réglée par compensation sur le reversement du client ; cette compensation a été retenue au débit le 23/11/2026 : la facture n'est pas réglée, et ce jour tient lieu d'échéance (règle du cabinet).",
    );
    expect(l.help).not.toContain("n'est pas réglée à son échéance");
    expect(checkLabel("post_opening_unpaid", { details: { opening_kind: "liquidation", due_date: "2026-11-20" } }).help).toContain(
      "Cette facture est née après le jugement d'ouverture et n'est pas réglée à son échéance.",
    );
  });
  // review round 3: a run's own invoice netted in full whose payout is not debited, once the client's invoice bar applies
  // (private.client_set_off_barred): unpaid from the day the bar was recorded (the row's `barred_on`, its `bar`)
  it.each([
    ["liquidation", "la liquidation judiciaire du client"],
    ["mandate_ended", "la fin du mandat"],
    ["seizure", "une saisie"],
  ])("a netted invoice whose payout is not debited, the bar %s recorded: unpaid from that day", (bar, cause) => {
    const l = checkLabel("post_opening_unpaid", {
      details: { opening_kind: "liquidation", number: "FC-2026-000011", due_date: null, withheld_on: null, barred_on: "2026-11-24", bar },
    });
    expect(l.help).toContain(
      `La facture FC-2026-000011 est née après le jugement d'ouverture. Elle devait être réglée par compensation sur le reversement du client, qui n'est pas débité ; depuis le 24/11/2026, jour où le cabinet a enregistré ${cause}, il ne compense plus (règle du cabinet) : la facture n'est pas réglée, et ce jour tient lieu d'échéance (règle du cabinet).`,
    );
    expect(l.help).toContain(
      "l'alerte s'arrête aussi quand elle est réglée, ou quand le reversement est annulé (son avoir annule la facture).",
    );
    expect(l.help).not.toContain("retenue au débit");
    expect(l.help).not.toContain("n'est pas réglée à son échéance");
  });
  // 7f-1 review round 1 (TUI-H15-BAR-DAY): a seizure recorded on 17/11, then a liquidation recorded on 25/11 — SQL dates
  // the invoice from the first recording among the bars in effect and names that bar in `bar` (the seizure), never the
  // strongest one with the first one's day (« … le 17/11/2026, jour où le cabinet a enregistré la liquidation … »: false)
  it("a seizure then a liquidation: dated and named by the seizure, the first bar recorded", () => {
    const h = checkLabel("post_opening_unpaid", {
      details: {
        opening_kind: "proceeding_opened",
        liquidation_on: "2026-11-25",
        number: "FC-2026-000012",
        due_date: null,
        withheld_on: null,
        barred_on: "2026-11-17",
        bar: "seizure",
      },
    }).help;
    expect(h).toContain("depuis le 17/11/2026, jour où le cabinet a enregistré une saisie, il ne compense plus (règle du cabinet)");
    expect(h).not.toContain("enregistré la liquidation judiciaire du client");
    // in liquidation by then: the liquidation's text governs the alert (L641-13 III)
    expect(h).toContain("(art. L641-13 III C. com.)");
  });
});

describe("payout_after_liquidation and its disposition (§6.3, [critic] L11, [check 1] gap 9)", () => {
  const inFile = { client_id: CLIENT, status: "in_file", cancellable: false, downloaded: true, liquidation_on: "2026-11-23" };
  it("words the payout and L641-9 as read — « payé » only once debited", () => {
    const l = checkLabel("payout_after_liquidation", { details: inFile });
    expect(l.label).toBe("Reversement au client après sa liquidation");
    expect(l.help).toContain("Un reversement à payer au client après le jugement de liquidation, sur un compte");
    expect(checkLabel("payout_after_liquidation", { details: { ...inFile, status: "booked" } }).help).toContain(
      "Un reversement payé au client après le jugement de liquidation, sur un compte",
    );
  });
  // review round 1 (ML-4, TUI-2): L641-9 I as read (version of 2022-05-15): the qualifier kept, the cut marked
  it("quotes L641-9 I with its qualifier, the cut marked, and its second sentence whole", () => {
    const h = checkLabel("payout_after_liquidation", { details: { ...inFile, status: "booked" } }).help;
    expect(h).toContain(
      "le jugement « emporte de plein droit, à partir de sa date, dessaisissement pour le débiteur de l'administration et de la disposition de ses biens composant le patrimoine engagé par l'activité professionnelle […] » ; « Les droits et actions du débiteur concernant son patrimoine sont exercés pendant toute la durée de la liquidation judiciaire par le liquidateur. » (art. L641-9 I C. com.).",
    );
    expect(h).not.toContain("de ses biens » (art. L641-9");
  });
  it("in a downloaded file, the switch off: sends ops to the bank", () => {
    expect(checkLabel("payout_after_liquidation", { details: inFile }).help).toContain(
      "Le virement est dans un fichier déjà téléchargé : Collectoo ne peut plus l'annuler ; demandez à la banque de ne pas l'exécuter.",
    );
  });
  it("cancellable (the switch on, or a file not downloaded): sends ops to the cancellation", () => {
    expect(
      checkLabel("payout_after_liquidation", { cancellationAfterDownload: true, details: { ...inFile, cancellable: true } }).help,
    ).toContain("Annulez-le depuis la page du fichier (annulation en deux temps, relevés à l'appui)");
    expect(checkLabel("payout_after_liquidation", { details: { ...inFile, cancellable: true, downloaded: false } }).help).toContain(
      "Le fichier n'est pas téléchargé : annulez le reversement",
    );
  });
  it("booked: never stops by itself, the disposition recorded stops it", () => {
    const h = checkLabel("payout_after_liquidation", { details: { ...inFile, status: "booked" } }).help;
    expect(h).toContain("« Enregistrer la suite »");
    expect(h).toContain("l'alerte reste jusque-là");
    expect(h).toContain("OQ-99");
  });
  it("leads to the client's events", () => {
    expect(checkSubjectLink({ code: "payout_after_liquidation", subject_type: "bank_transfer", subject_id: "t", details: inFile })).toBe(
      `/backoffice/clients/${CLIENT}/reversement#evenements`,
    );
  });
  it("names the two dispositions and every refusal", () => {
    expect(DISPOSITION_KIND).toEqual({
      ratified: "Ratifié par le liquidateur",
      repaid_to_liquidator: "Somme reversée au liquidateur",
    });
    expect(dispositionRefusal("liquidation payout disposition refused: already_disposed")).toBe(
      "Une suite est déjà enregistrée pour ce reversement.",
    );
    expect(dispositionRefusal("liquidation payout disposition refused: not_after_liquidation")).toBe(
      "Ce virement n'est pas un reversement fait au client après sa liquidation : rien à enregistrer.",
    );
    expect(dispositionRefusal("liquidation payout disposition refused: bad_kind")).toBe(
      "Choisissez : ratifié par le liquidateur, ou somme reversée au liquidateur.",
    );
    expect(dispositionRefusal("liquidation payout disposition refused: evidence_required")).toBe("Joignez la pièce justificative.");
    expect(dispositionRefusal("not allowed")).toBe("Réservé aux administrateurs du cabinet (double authentification).");
  });
});

describe("the outcome of a set-off set_off_after_bar alerts (carried item 2)", () => {
  it("records « compensation maintenue » only, and says giving it back is not built", () => {
    expect(outcomeRefusal("set-off outcome refused: bad_kind")).toBe(
      "Seule « compensation maintenue » peut être enregistrée : rendre la somme au client ne se fait pas encore dans Collectoo (prévenez le support).",
    );
    expect(outcomeRefusal("set-off outcome refused: not_alerted")).toBe(
      "Cette écriture n'est pas une compensation signalée après une procédure, une fin de mandat ou une saisie.",
    );
    expect(outcomeRefusal("set-off outcome refused: already_recorded")).toBe("L'issue de cette compensation est déjà enregistrée.");
    expect(checkLabel("set_off_after_bar").help).toContain("« Compensation maintenue »");
  });
});

describe("the advances' and the invoices' alerts after 7d-3 (§6.2.10; carried item 1, [critic] L9)", () => {
  it("advance_open no longer lists a client in a proceeding's advance: it is to declare, and listed there", () => {
    // the advance_open text is 7b's (pinned by advances.test.ts and remitted.test.ts): it already says « à déclarer »
    expect(checkLabel("advance_open").help).toContain(
      "client en procédure collective ou en liquidation : ni reprise ni demande, elle est à déclarer (règle du cabinet)",
    );
    expect(claimsToDeclareHelp({ document_kind: "advance", born_on: "2026-10-01" })).toContain(
      "chaque avance du cabinet ouverte, quelle que soit sa date",
    );
  });
  // review round 2: the netted invoice whose set-off the debit withheld (a mandate's end, a seizure) is dunned too
  it("invoice_overdue names the netted invoice whose set-off the debit withheld", () => {
    expect(checkLabel("invoice_overdue").help).toContain(
      "une facture à régler au compte propre, une facture rétablie par l'annulation d'un reversement que le reversement suivant n'a pas compensée à temps, ou une facture à régler par compensation sur son reversement dont la compensation a été retenue au débit (fin du mandat, saisie : impayée depuis ce débit, règle du cabinet).",
    );
  });
  it("invoice_overdue says what it leaves out", () => {
    expect(checkLabel("invoice_overdue").help).toContain(
      "Préparez le reversement du client ou vérifiez son règlement (les factures d'un client en procédure collective nées avant le jugement, et celles d'un client en liquidation, ne sont pas listées ici ; tant qu'elles ne sont pas déclarées, elles le sont dans « Créance du cabinet à déclarer » ou « Facture née après le jugement, impayée à son échéance »).",
    );
  });
});

describe("a withheld set-off given back after a return (carried item 4)", () => {
  const w = {
    withheld_minor: "20000",
    commission_minor: "20000",
    advances_minor: "0",
    refund_unpaid_minor: "0",
    withheld_on: "2026-11-22",
    reason: "Compensation retenue : procédure collective depuis le 19/11/2026 (règle du cabinet)",
    set_off_commission_minor: "0",
    set_off_advances_minor: "0",
    given_back_by: "RV-2026-000009",
    giving_back_by: null,
    returned_by: "RV-2026-000008",
  };
  it("names the run that paid it again and the one whose payout came back", () => {
    expect(runWithheldNotes(parseRunWithheld(w)!, "EUR")[0]).toBe(
      "Compensation retenue au débit le 22/11/2026 : 200,00 € (factures 200,00 €) — procédure collective depuis le 19/11/2026 (règle du cabinet) ; rendue au client par le reversement RV-2026-000009 (le virement du reversement RV-2026-000008 était revenu)",
    );
  });
  it("while the sum is re-queued after the return: never « rendue »", () => {
    const note = runWithheldNotes(parseRunWithheld({ ...w, given_back_by: null })!, "EUR")[0];
    expect(note).toContain(
      "à rendre au client par le prochain reversement (le virement du reversement RV-2026-000008 qui la rendait est revenu)",
    );
    expect(note).not.toContain("rendue au client");
  });
  it("reads a payload without returned_by (before 7d-3) as none", () => {
    const old: Record<string, unknown> = { ...w };
    delete old.returned_by;
    expect(parseRunWithheld(old)?.returned_by ?? null).toBeNull();
    expect(runWithheldNotes(parseRunWithheld(old)!, "EUR")[0]).not.toContain("était revenu");
  });
});
