import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { paymentActions } from "@/lib/payments/allocation";
import { CHECK_LABEL } from "@/lib/payments/debits";
import { REASON_FILTERS, reviewReason } from "@/lib/payments/matching";
import { FEED_REASON } from "@/lib/payments/receipts";
import {
  EVENT_HINT,
  PAYOUT_KIND,
  REPRESENTATIVE_ROLE,
  addresseeLines,
  declaredFromForm,
  eventLine,
  parseClientEvents,
  payeeRule,
  representativeFromForm,
  standingSeizures,
} from "./client-events";
import { repaymentRefusal } from "./requests";
import { blockerLabel, failureLabel } from "./runs";
import { DOCUMENT_KIND, EVENT_BLOCKERS, EVENT_KIND, identityErrorCode, readinessText } from "./terms";

// M2c-7d-1 (plan docs/design/m2c-7-plan.md §6.4): the client's events, who acts for it, the payee after each event,
// the payments after the mandate's end, the letters' addressees. Every rule is SQL's; these only word it, and never
// present the servicer's rule as the law's.

const DEATH = "11111111-1111-4111-8111-111111111111";
const SEIZURE = "22222222-2222-4222-8222-222222222222";
const RELEASE = "33333333-3333-4333-8333-333333333333";
const OLD = "44444444-4444-4444-8444-444444444444";

describe("the events' kinds (LEX-25)", () => {
  it("names a tutelle alone, a curatelle as the servicer's rule, a declaration, a seizure and its release", () => {
    expect(EVENT_KIND.guardianship).toBe("Tutelle");
    expect(EVENT_KIND.curatorship).toBe("Curatelle ou autre mesure de protection (règle du cabinet)");
    expect(EVENT_KIND.claims_declared).toBe(
      "Créances du cabinet déclarées au mandataire judiciaire (ou au liquidateur)",
    );
    expect(EVENT_KIND.seizure).toBe("Saisie entre les mains du cabinet");
    expect(EVENT_KIND.seizure_released).toBe("Mainlevée de la saisie");
    expect(DOCUMENT_KIND.payout_authority_evidence).toBe(
      "Pièce désignant qui peut recevoir (attestation du notaire, jugement)",
    );
  });
  it("words the notification date of a mandate's end from the articles read (2006, 2007 C. civ.)", () => {
    expect(EVENT_HINT.mandate_ended).toBe(
      "Date d'effet : pour une révocation, le jour où elle a été notifiée au cabinet (la désignation d'un nouveau mandataire vaut révocation « à compter du jour où elle a été notifiée », art. 2006 C. civ.) ; pour une renonciation du cabinet, le jour où elle a été notifiée au client (art. 2007 C. civ.).",
    );
  });
  it("names who acts for the client and the payout accounts' kinds", () => {
    expect(REPRESENTATIVE_ROLE).toEqual({
      notary: "Notaire",
      heirs: "Héritiers",
      tutor: "Tuteur",
      curator: "Curateur",
      liquidator: "Liquidateur",
      administrator: "Administrateur judiciaire",
    });
    expect(PAYOUT_KIND.estate).toBe("Succession — compte du notaire, ou compte désigné par tous les héritiers");
    // (review round 1, TUI-7) C. civ. 427 al. 5 requires the account in the person's name; who makes it work depends on
    // the measure (440, 472: a curator receives the income only in a curatelle renforcée) — never stated as the tutor's
    expect(PAYOUT_KIND.protected_adult).toBe("Compte du majeur protégé, ouvert à son nom (art. 427 C. civ.)");
    expect(PAYOUT_KIND.court_appointed).toBe("Un mandataire de justice (liquidateur, administrateur)");
    expect(PAYOUT_KIND.client).toBe("Le client");
  });
});

describe("the commands' refusals in French", () => {
  const cases: [string, string][] = [
    ["client event refused: claims_declared_without_proceeding", "Aucune procédure collective n'est enregistrée pour ce client."],
    ["client event refused: bad_publication_date", "La date de publication ne peut précéder le jugement ni être dans le futur."],
    [
      "client event refused: release_without_seizure",
      "Désignez la saisie levée : une saisie de ce client encore en cours, antérieure à la mainlevée.",
    ],
    ["client event refused: refers_to_not_allowed", "Seule une mainlevée désigne un autre événement : la saisie qu'elle lève."],
    [
      "client event refused: not_declarable",
      "Déclarez seulement des factures ou des avances de ce client, chacune pour un montant positif, avec une déclaration de créances.",
    ],
    ["client representative refused: not_an_event_with_representative", "Cet événement ne désigne personne qui agisse pour le client."],
    ["client event refused: bad_representative", "Indiquez le rôle, le nom et l'adresse (quatre lignes au plus)."],
    [
      "client representative refused: role_mismatch",
      "Ce rôle ne correspond pas à l'événement (tuteur pour une tutelle, curateur pour une curatelle, notaire ou héritiers pour un décès, liquidateur pour une liquidation, administrateur pour une procédure).",
    ],
    ["client representative refused: evidence_required", "Joignez la pièce justificative."],
    [
      "protection qualification refused: not_an_old_guardianship",
      "Seuls les événements « Tutelle ou curatelle » enregistrés avant cette version sont à préciser.",
    ],
    ["protection qualification refused: already_qualified", "Cet événement est déjà précisé."],
    ["protection qualification refused: evidence_required", "Joignez le jugement."],
    ["payout account refused: estate_without_death", "Un compte de succession suppose un décès enregistré."],
    [
      "payout account refused: protected_adult_without_measure",
      "Un compte de majeur protégé suppose une tutelle ou une curatelle enregistrée.",
    ],
    [
      "payout account refused: holder_not_client",
      "Le titulaire du RIB n'a pas le nom du client. Le compte doit être au nom du client (art. 427 C. civ.) ; si le RIB l'écrit autrement, expliquez pourquoi : un second administrateur vérifiera.",
    ],
    [
      "payout account refused: authority_evidence_required",
      "Joignez la pièce qui désigne qui peut recevoir (attestation du notaire ou désignation par tous les héritiers, jugement nommant le tuteur, le curateur ou le liquidateur).",
    ],
    ["payout account refused: bad_attestation", "L'explication tient en 500 caractères au plus."],
    // (review round 1, CC-3) the commands on the payout_accounts: lock wait 2 s at most
    [
      "canceling statement due to lock timeout",
      "Une décision sur les comptes de reversement ou les événements des clients du cabinet est en cours : réessayez dans un instant.",
    ],
  ];
  it.each(cases)("%s", (message, text) => {
    expect(errorText(identityErrorCode(message))).toBe(text);
  });
  it("keeps the court-appointed refusal true of every event that takes the client's users off its accounts", () => {
    const text = errorText(identityErrorCode("payout account refused: court_appointed"));
    expect(text).toContain("décès");
    expect(text).toContain("tutelle ou curatelle");
    expect(text).toContain("saisie");
    expect(text).toContain("second administrateur du cabinet");
    expect(text).toContain("règle du cabinet");
  });
});

describe("the payee after each event (runs' blockers, with their exit)", () => {
  it("says what lifts each block", () => {
    expect(blockerLabel("client_status:death")).toBe(
      "Décès du client : confirmez le compte du notaire, ou celui que tous les héritiers désignent, avec la pièce (second administrateur)",
    );
    expect(blockerLabel("client_status:guardianship")).toBe(
      "Client sous tutelle ou curatelle : confirmez un compte ouvert à son nom (art. 427 C. civ.), avec le jugement (second administrateur)",
    );
    expect(blockerLabel("client_status:curatorship")).toBe(blockerLabel("client_status:guardianship"));
    // (review round 1, MONEY-LAW-1) an old row: no account lifts it before it is qualified
    expect(blockerLabel("client_status:guardianship_to_qualify")).toBe(
      "« Tutelle ou curatelle » enregistrée avant leur distinction : précisez-la avec le jugement (« Événements du client ») ; aucun compte ne lève ce blocage avant (règle du cabinet)",
    );
    expect(blockerLabel("client_status:mandate_ended")).toBe(
      "Mandat terminé : confirmez à nouveau le compte du client (second administrateur)",
    );
    // (review round 1, MONEY-LAW-3, TUI-1) what 7d-1 did: the payouts only — (M2c-7d-2, R3) the set-off barred too,
    // whatever the run's net (plan §6.2.9 [critic] L14; the label of §6.4)
    expect(blockerLabel("client_status:seizure")).toBe(
      "Saisie entre les mains du cabinet : ni reversement ni compensation jusqu'à la mainlevée",
    );
    expect(blockerLabel("client_status:liquidation")).toBe(
      "Client en liquidation : compte du liquidateur à confirmer, avec le jugement qui le nomme (second administrateur)",
    );
    // (M2c-7d-2, R3) as above: the approval's refusal of a run under a seizure, whatever N
    expect(failureLabel("payout_blocked:client_status:seizure")).toBe(
      "virement bloqué — Saisie entre les mains du cabinet : ni reversement ni compensation jusqu'à la mainlevée",
    );
  });
  it("states the payee the events require", () => {
    expect(payeeRule({ kind: "estate", event_kind: "death" })).toBe(
      "Compte exigé : celui de la succession (compte du notaire, ou compte désigné par tous les héritiers), avec sa pièce, confirmé par un second administrateur après l'événement.",
    );
    expect(payeeRule({ kind: "protected_adult", event_kind: "curatorship" })).toBe(
      "Compte exigé : un compte ouvert au nom du client (art. 427 C. civ.), avec le jugement, confirmé par un second administrateur après l'événement.",
    );
    // (review round 1, MONEY-LAW-1) an old row to qualify: no account
    expect(payeeRule({ kind: "to_qualify", event_kind: "guardianship_to_qualify" })).toBe(
      "Reversements bloqués tant que la « Tutelle ou curatelle » enregistrée n'est pas précisée (« Préciser : tutelle ou curatelle », avec le jugement) : aucun compte ne lève ce blocage avant (règle du cabinet).",
    );
    expect(payeeRule(null)).toBe("");
  });
});

describe("the events' page read", () => {
  const view = {
    events: [
      {
        id: DEATH, kind: "death", effective_kind: "death", effective_date: "2026-11-20", recorded_on: "2026-11-21",
        publication_date: null, note: null, evidence_document_id: DEATH, refers_to_event_id: null, standing: null,
        released_on: null, to_qualify: false, qualification: null,
        representative: { role: "notary", name: "Me Claire Lenoir, notaire", address_lines: ["3 place du Palais", "69002 Lyon"], recorded_on: "2026-11-21", evidence_document_id: DEATH },
        representatives: 2, declared: [],
      },
      {
        id: SEIZURE, kind: "seizure", effective_kind: "seizure", effective_date: "2026-11-10", recorded_on: "2026-11-10",
        publication_date: null, note: null, evidence_document_id: SEIZURE, refers_to_event_id: null, standing: true,
        released_on: null, to_qualify: false, qualification: null, representative: null, representatives: 0, declared: [],
      },
      {
        id: RELEASE, kind: "seizure_released", effective_kind: "seizure_released", effective_date: "2026-11-22",
        recorded_on: "2026-11-22", publication_date: null, note: null, evidence_document_id: RELEASE,
        refers_to_event_id: "55555555-5555-4555-8555-555555555555", standing: null, released_on: null,
        to_qualify: false, qualification: null, representative: null, representatives: 0, declared: [],
      },
      {
        id: OLD, kind: "guardianship", effective_kind: "guardianship_to_qualify", effective_date: "2026-01-10",
        recorded_on: "2026-01-11", publication_date: null, note: null, evidence_document_id: OLD,
        refers_to_event_id: null, standing: null, released_on: null, to_qualify: true, qualification: null,
        representative: null, representatives: 0, declared: [],
      },
    ],
    payee: { kind: "estate", event_kind: "death" },
    addressees: [{ role: "notary", name: "Me Claire Lenoir, notaire", address_lines: ["3 place du Palais", "69002 Lyon"], copy: false }],
    accounts: [],
  };
  it("parses it and lists the standing seizures a release may name", () => {
    const v = parseClientEvents(view);
    expect(v?.events.map((e) => e.kind)).toEqual(["death", "seizure", "seizure_released", "guardianship"]);
    expect(standingSeizures(v!.events).map((e) => e.id)).toEqual([SEIZURE]);
    expect(addresseeLines(v!.addressees)).toEqual([
      "Me Claire Lenoir, notaire (notaire) — 3 place du Palais, 69002 Lyon",
    ]);
    expect(parseClientEvents({ events: "x" })).toBeNull();
  });
  it("says when nobody is recorded to receive the letters", () => {
    // (review round 1, TUI-6) an old row is qualified first (no representative before); the heirs too
    expect(addresseeLines([])).toEqual([
      "Personne n'est enregistré pour recevoir les courriers : indiquez qui agit pour le client (notaire ou héritiers, tuteur, curateur ou liquidateur ; une « Tutelle ou curatelle » enregistrée avant leur distinction se précise d'abord).",
    ]);
    expect(
      addresseeLines([
        { role: "client", name: "Cyprès SA", address_lines: ["1 rue de la Paix", "75002 Paris"], copy: false },
        { role: "curator", name: "Association Tutélaire de Lyon", address_lines: ["3 place du Palais", "69002 Lyon"], copy: true },
      ]),
    ).toEqual([
      "Cyprès SA — 1 rue de la Paix, 75002 Paris",
      "Copie : Association Tutélaire de Lyon (curateur) — 3 place du Palais, 69002 Lyon",
    ]);
  });
});

describe("an event's line (review round 1, TUI-2)", () => {
  const base = {
    id: OLD, kind: "guardianship", effective_kind: "guardianship_to_qualify", effective_date: "2026-01-10",
    recorded_on: "2026-01-11", publication_date: null, note: null, evidence_document_id: OLD, refers_to_event_id: null,
    standing: null, released_on: null, to_qualify: true, qualification: null, representative: null, representatives: 0,
    declared: [],
  };
  it("names an old row by what it was recorded as, then what it was qualified as — never « Tutelle » alone", () => {
    expect(eventLine(base)).toBe("10/01/2026 · Tutelle ou curatelle (à préciser) · enregistré le 11/01/2026");
    expect(
      eventLine({
        ...base, effective_kind: null, to_qualify: false,
        qualification: { kind: "curatorship", curatorship_event_id: DEATH, evidence_document_id: OLD, recorded_on: "2026-11-20" },
      }),
    ).toBe("10/01/2026 · Tutelle ou curatelle — précisé : curatelle · enregistré le 11/01/2026");
    expect(
      eventLine({
        ...base, effective_kind: "guardianship", to_qualify: false,
        qualification: { kind: "guardianship", curatorship_event_id: null, evidence_document_id: OLD, recorded_on: "2026-11-20" },
      }),
    ).toBe("10/01/2026 · Tutelle ou curatelle — précisé : tutelle · enregistré le 11/01/2026");
    expect(eventLine({ ...base, effective_kind: "guardianship", to_qualify: false })).toBe(
      "10/01/2026 · Tutelle · enregistré le 11/01/2026",
    );
  });
});

describe("the portfolio confirmation gate after an old row (review round 1, TUI-2)", () => {
  it("states no end of mandate for a row to qualify", () => {
    expect(readinessText("client_protection_to_qualify:2026-11-14")).toBe(
      "« Tutelle ou curatelle » du 14/11/2026 à préciser : pas de nouveau portefeuille pour ce client avant (règle du cabinet ; une tutelle met fin au mandat, art. 2003 C. civ., une curatelle non)",
    );
    expect(EVENT_BLOCKERS).toContain("client_protection_to_qualify");
  });
});

describe("the forms", () => {
  it("reads the person who acts for the client (role, name, up to four address lines)", () => {
    const f = new FormData();
    f.set("rep_role", "notary");
    f.set("rep_name", "  Me Claire Lenoir  ");
    f.set("rep_address", "3 place du Palais\n\n69002 Lyon\n");
    expect(representativeFromForm(f)).toEqual({
      role: "notary",
      name: "Me Claire Lenoir",
      address_lines: ["3 place du Palais", "69002 Lyon"],
    });
    expect(representativeFromForm(new FormData())).toBeNull();
    const g = new FormData();
    g.set("rep_role", "tutor");
    expect(representativeFromForm(g)).toEqual({ role: "tutor", name: "", address_lines: [] });
  });
  it("reads the declared documents and their amounts in euros, as minor units in text", () => {
    const f = new FormData();
    f.append("declared", `invoice:${DEATH}`);
    f.set(`declared_amount_${DEATH}`, "180,00");
    f.append("declared", `advance:${SEIZURE}`);
    f.set(`declared_amount_${SEIZURE}`, "300");
    expect(declaredFromForm(f)).toEqual([
      { document_kind: "invoice", document_id: DEATH, amount_minor: "18000" },
      { document_kind: "advance", document_id: SEIZURE, amount_minor: "30000" },
    ]);
    const bad = new FormData();
    bad.append("declared", `invoice:${DEATH}`);
    bad.set(`declared_amount_${DEATH}`, "1,2,3");
    expect(declaredFromForm(bad)).toEqual([{ document_kind: "invoice", document_id: DEATH, amount_minor: "" }]);
  });
});

describe("payments received after the mandate's end (§6.2.8, founder Q10)", () => {
  it("are held for ops, with what ops may do", () => {
    expect(reviewReason("client_mandate_ended")).toEqual({
      label: "Reçu après la fin du mandat",
      tone: "action",
      help: "Reçu après la fin du mandat du client : à reverser au client (ou à son bénéficiaire) ou à restituer au payeur.",
    });
    expect(REASON_FILTERS.map((r) => r.value)).toContain("client_mandate_ended");
    expect(FEED_REASON.mandate_ended).toBe("Paiement reçu après la fin du mandat : il vous est reversé sans être imputé.");
  });
  it("offer « Reverser au client »", () => {
    const d = {
      payment: { status: "matched", review_reason: "client_mandate_ended" },
      position: { allocated_minor: "0", unallocated_minor: "50000", returned_minor: "0" },
      file: { status: "in_collection", holds: [] },
      entries: [],
      other_files: [],
    } as unknown as Parameters<typeof paymentActions>[0];
    expect(paymentActions(d).forward).toBe(true);
    expect(paymentActions(d).allocate).toBe(false);
  });
});

describe("the nightly's new checks and the repayment request's recipient", () => {
  it("words them", () => {
    expect(CHECK_LABEL.protection_event_to_qualify.label).toBe("Tutelle ou curatelle à préciser");
    expect(CHECK_LABEL.seizure_standing.label).toBe("Saisie entre les mains du cabinet en cours");
    expect(CHECK_LABEL.seizure_standing.help).toContain("L211-3");
    // (review round 1, TUI-6) an old row is qualified first; the heirs too
    expect(repaymentRefusal("repayment request refused: recipient_unknown")).toBe(
      "Indiquez d'abord qui agit pour le client (notaire ou héritiers, tuteur, curateur ou liquidateur ; une « Tutelle ou curatelle » enregistrée avant leur distinction se précise d'abord) : la lettre lui est adressée, ou en copie au curateur.",
    );
  });
  // (M2c-7d-2, R3) what a seizure blocks once 7d-2 bars the set-off whatever N (plan §6.2.6, §6.2.9): the payouts and
  // the set-off, an N = 0 run refused, a set-off approved before withheld at the debit — no longer « ne bloque pas
  // encore » (7d-1's text, review round 1, MONEY-LAW-3, TUI-1)
  it("say what a seizure blocks, payouts and set-off alike", () => {
    const help = CHECK_LABEL.seizure_standing.help;
    expect(help).toContain("ni virement de reversement ni compensation tant que la mainlevée n'est pas enregistrée");
    expect(help).toContain("un reversement, même entièrement compensé, est refusé à la validation");
    expect(help).not.toContain("ne bloque pas encore");
    expect(help).toContain("« La compensation ne préjudicie pas aux droits acquis par des tiers » (art. 1347-7 C. civ.)");
    expect(CHECK_LABEL.protection_event_to_qualify.help).toContain("les reversements du client restent bloqués");
  });
});

describe("LEX-28: never « abandon » or « remise » toward the client", () => {
  it("in the slice's texts", () => {
    const src = ["client-events.ts", "terms.ts"].map((f) => readFileSync(join(__dirname, f), "utf8")).join("\n");
    expect(src).not.toMatch(/abandon|remise de dette/i);
  });
});
