import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import {
  READINESS_LABEL,
  addressFromForm,
  addressText,
  cleanSiren,
  identityErrorCode,
  issuerLines,
  rateText,
  scheduleInWords,
  termsInWords,
} from "./terms";

const plain = (s: string) => s.replace(/[  ]/g, " ");

// design §8.1's example
const SCHEDULE = {
  schema: "commission-1",
  basis: {
    families: "all",
    forwards: { file_recalled: false, before_servicing_start: false, client_ratification: false },
    on_reversal: "credit",
  },
  rules: [
    {
      id: "b2b",
      tier_key: "b2b",
      label_fr: "Factures entre professionnels",
      match: { claim_types: ["b2b_invoice"] },
      rate: { kind: "flat", rate: "0.1500" },
    },
    {
      id: "autres",
      tier_key: "autres",
      label_fr: "Autres créances",
      match: {},
      rate: {
        kind: "marginal",
        tiers: [
          { up_to_minor: "500000", rate: "0.1000" },
          { up_to_minor: null, rate: "0.0600" },
        ],
      },
      min_per_file_minor: "3000",
    },
  ],
};

describe("rateText", () => {
  it("prints decimal rate strings as French percentages, without floats", () => {
    expect(["0.1500", "0.15", "0.125", "1", "1.0000", "0", "0.0600", "0.0001"].map((r) => plain(rateText(r)))).toEqual([
      "15 %",
      "15 %",
      "12,5 %",
      "100 %",
      "100 %",
      "0 %",
      "6 %",
      "0,01 %",
    ]);
  });
  it("leaves anything else as it is", () => {
    expect(rateText("abc")).toBe("abc");
  });
});

describe("scheduleInWords", () => {
  it("states the basis and each rule in order, in French", () => {
    expect(scheduleInWords(SCHEDULE, { b2b_invoice: "Facture B2B" }).map(plain)).toEqual([
      "Base : toutes les sommes imputées sur les créances du client",
      "Encaissement annulé ensuite : un avoir rectifie la commission",
      "Factures entre professionnels (Facture B2B) : 15 %",
      "Autres créances (tout le reste) : 10 % jusqu'à 5 000,00 €, 6 % au-delà de 5 000,00 € encaissés sur le dossier ; minimum 30,00 € par dossier",
    ]);
  });
  it("names families, forwards, kept commission and brackets", () => {
    const words = scheduleInWords({
      basis: {
        families: ["principal", "interest"],
        forwards: { file_recalled: true, before_servicing_start: false, client_ratification: true },
        on_reversal: "keep",
      },
      rules: [
        {
          id: "age",
          label_fr: "Selon l'ancienneté",
          match: {},
          rate: {
            kind: "bracket",
            attribute: "age_days_at_boarding",
            brackets: [
              { up_to: "365", rate: "0.12" },
              { up_to: null, rate: "0.2" },
            ],
          },
        },
      ],
    }).map(plain);
    expect(words).toEqual([
      "Base : principal, intérêts imputés",
      "Commission aussi sur les reversements sans imputation : dossier rappelé, ratification du client",
      "Encaissement annulé ensuite : la commission reste due (clause du mandat)",
      "Selon l'ancienneté (tout le reste) : 12 % si l'ancienneté de la créance à la reprise va jusqu'à 365 jours, sinon 20 % (taux unique pour le dossier)",
    ]);
  });
  it("says nothing of a missing schedule", () => {
    expect(scheduleInWords(null)).toEqual([]);
  });
});

describe("termsInWords", () => {
  it("states frequency, delay, compensation and claw-back", () => {
    expect(
      termsInWords(
        { schema: "remittance-1", frequency: "twice_monthly", netting: { clause_ref: "art. 7.2" }, clawback: null, invoice_payment_days: 30 },
        30,
      ),
    ).toEqual([
      "Reversements deux fois par mois, le 1er et le 16 (ou le jour ouvré suivant)",
      "Délai : au plus 30 jours après l'encaissement, et jamais plus d'un mois (art. R124-6 CPCE)",
      "Commission compensée sur chaque reversement (art. 7.2)",
      "Avances du cabinet : demande de remboursement (pas de clause de reprise)",
    ]);
    expect(
      termsInWords({ frequency: "weekly", weekday: 2, netting: null, clawback: { clause_ref: "art. 7.4" }, invoice_payment_days: 45 }, 1),
    ).toEqual([
      "Reversements chaque semaine, le mardi (ou le jour ouvré suivant)",
      "Délai : au plus 1 jour après l'encaissement, et jamais plus d'un mois (art. R124-6 CPCE)",
      "Pas de compensation : reversement brut, facture payable sous 45 jours sur le compte propre du cabinet",
      "Avances du cabinet reprises sur les reversements suivants (art. 7.4)",
    ]);
  });
});

describe("addresses", () => {
  it("prints an address on one line, the country outside France", () => {
    expect(addressText({ line1: "10 rue de la Bourse", postcode: "75002", city: "Paris", country: "FR" })).toBe(
      "10 rue de la Bourse, 75002 Paris",
    );
    expect(addressText({ line1: "1 rue X", line2: "Bât. B", postcode: "98000", city: "Monaco", country: "MC" })).toBe(
      "1 rue X, Bât. B, 98000 Monaco, Monaco",
    );
  });
  it("reads the address fields of a form", () => {
    const form = new FormData();
    form.set("office_line1", " 12 rue des Artisans ");
    form.set("office_postcode", "69003");
    form.set("office_city", "Lyon");
    form.set("office_country", "fr");
    expect(addressFromForm(form, "office")).toEqual({ line1: "12 rue des Artisans", postcode: "69003", city: "Lyon", country: "FR" });
    expect(addressFromForm(new FormData(), "billing")).toBeNull();
  });
  it("cleans a SIREN typed with spaces", () => {
    expect(cleanSiren("849 678 297")).toBe("849678297");
  });
});

describe("issuerLines", () => {
  const identity = {
    legal_form: "SAS",
    share_capital_minor: "1000000",
    rcs_city: "Paris",
    registered_office: { line1: "10 rue de la Bourse", postcode: "75002", city: "Paris", country: "FR" },
    billing_address: null,
    vat_number: "FR33849678297",
    is_professional: true,
    in_liquidation: false,
    invoice_acceptance_ref: null,
    version: 1,
  };
  it("are the receipt's issuer block (the worker's issuer_block)", () => {
    expect(issuerLines("Collectoo", "849678297", identity).map(plain)).toEqual([
      "Collectoo SAS au capital de 10 000 €",
      "SIREN 849 678 297 · RCS Paris",
      "Siège social : 10 rue de la Bourse, 75002 Paris",
    ]);
    expect(plain(issuerLines("Collectoo", "849678297", { ...identity, share_capital_minor: 1000050, in_liquidation: true })[0])).toBe(
      "Collectoo SAS au capital de 10 000,50 € – en liquidation",
    );
    expect(issuerLines("Collectoo", null, identity)).toEqual(["Collectoo"]);
  });
});

describe("identityErrorCode", () => {
  it("maps the commands' errors to fixed French messages", () => {
    const cases: [string, string][] = [
      ["payout account: the person who proposed it cannot confirm it (a second person confirms)", "payout_same_person"],
      ["payout account: the IBAN typed is not the one proposed", "payout_iban_mismatch"],
      ["payout account: a proposal already waits for confirmation", "payout_pending"],
      ["billing identity: the VAT number does not match the SIREN", "vat_mismatch"],
      ["billing identity changed since it was read", "changed_since_read"],
      ["mandate terms: invalid commission schedule (rules.last_not_catch_all)", "schedule_invalid"],
      ["mandate terms: a new version never starts before today (2026-11-10)", "terms_past"],
      ["the own account is named in the billing settings: choose another one first", "own_account_in_settings"],
      ["not allowed", "not_allowed"],
      ["something else", "unknown"],
    ];
    for (const [message, code] of cases) expect(identityErrorCode(message)).toBe(code);
    expect(errorText(identityErrorCode("payout account: no longer waiting for confirmation"))).toContain("confirmation");
  });
});

describe("READINESS_LABEL", () => {
  it("words every reason the confirmation gate gives", () => {
    const sqlReasons = [
      "no_active_mandate",
      "insurance_clause_missing",
      "commission_schedule_missing",
      "commission_clause_missing",
      "remittance_terms_missing",
      "remittance_clause_missing",
      "terms_document_missing",
      "servicer_identity_incomplete",
      "client_identity_incomplete",
      "client_not_professional",
      "client_not_mainland_france",
      "currency_not_eur",
    ];
    expect(Object.keys(READINESS_LABEL).sort()).toEqual([...sqlReasons].sort());
  });
});
