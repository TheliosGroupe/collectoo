import { describe, expect, it } from "vitest";
import { money } from "@/lib/payments/statements";
import {
  NOT_ONLINE_TEXT,
  csvAmount,
  csvFile,
  exportPeriod,
  frenchDay,
  inFlightNotes,
  invoiceDelivery,
  invoiceKind,
  listPage,
  neutraliseText,
  pageOf,
  runStatementState,
  runStatusText,
  settlementText,
  statementRunView,
} from "./documents";

describe("M2c-5 documents", () => {
  it("serves an invoice's PDF only once the buyer accepted electronic invoices (CGI 289 VI)", () => {
    expect(invoiceDelivery({ payload: { buyer: { invoice_acceptance_ref: "art. 11" } } }, { document_id: "d1" })).toEqual({
      mode: "pdf",
      documentId: "d1",
    });
    expect(invoiceDelivery({ payload: { buyer: { invoice_acceptance_ref: "art. 11" } } }, null)).toEqual({ mode: "pending" });
    expect(invoiceDelivery({ payload: { buyer: { invoice_acceptance_ref: null } } }, { document_id: "d1" })).toEqual({
      mode: "not_online",
    });
    expect(invoiceDelivery({ payload: { buyer: { invoice_acceptance_ref: "  " } } }, null)).toEqual({ mode: "not_online" });
    expect(invoiceDelivery({ payload: null }, null)).toEqual({ mode: "not_online" });
  });

  it("never claims a postal dispatch nothing records (review M2c-5 legal#7, K6)", () => {
    expect(NOT_ONLINE_TEXT).toBe(
      "PDF non disponible en ligne : vous n'aviez pas accepté la facture électronique à son émission. Demandez-la au cabinet.",
    );
    expect(NOT_ONLINE_TEXT).not.toMatch(/courrier|adress|envoy|transmis/i);
  });

  it("never says paid before the bank's debit", () => {
    const words = [
      runStatusText("approved", "164000"),
      runStatusText("sent", "164000"),
      runStatusText("booked", "0"),
      runStatusText("cancelled", "164000"),
      settlementText({ kind: "invoice", settlement: "netted", due_date: null }),
      settlementText({ kind: "invoice", settlement: "due", due_date: "2026-12-02" }),
      settlementText({ kind: "credit_note", settlement: "netted", due_date: null }),
    ];
    expect(words).toEqual([
      "Virement ordonné",
      "Virement ordonné",
      "Réglé par compensation, sans virement",
      "Annulé avant son exécution",
      "à régler par compensation sur un reversement",
      "à régler au plus tard le 02/12/2026",
      "déduit des factures qu'il rectifie",
    ]);
    expect(words.filter((w) => /payé/i.test(w))).toEqual([]);
    expect(invoiceKind("credit_note")).toBe("Avoir");
    expect(invoiceKind("invoice")).toBe("Facture");
    expect(frenchDay("2026-11-02")).toBe("02/11/2026");
  });

  it("states what the run sets off and the remainder's date, as the invoice's PDF does (review M2c-5 legal#4, legal#5)", () => {
    const netted = { kind: "invoice", settlement: "netted" } as const;
    // the plan sets off part of it: the remainder carries the invoice's due_date (its latest date)
    expect(
      settlementText({
        ...netted,
        due_date: "2026-12-10",
        payment_reference: {
          mode: "run",
          run_number: "RV-2026-000002",
          execution_date: "2026-11-12",
          transfer: true,
          amount_minor: "2000",
          remainder_minor: "4000",
          latest_date: "2026-12-10",
        },
      }),
    ).toBe(
      `à régler par compensation sur le reversement RV-2026-000002 : ${money("2000", "EUR")} ; le solde de ${money("4000", "EUR")} sur le prochain reversement, au plus tard le 10/12/2026`,
    );
    // the plan sets off none of it
    expect(
      settlementText({
        ...netted,
        due_date: "2026-12-10",
        payment_reference: { mode: "next_run", latest_date: "2026-12-10", amount_minor: "6000" },
      }),
    ).toBe("à régler par compensation sur le prochain reversement, au plus tard le 10/12/2026");
    // all of it on the run
    expect(
      settlementText({
        ...netted,
        due_date: null,
        payment_reference: {
          mode: "run",
          run_number: "RV-2026-000002",
          execution_date: "2026-11-12",
          transfer: true,
          amount_minor: "6000",
        },
      }),
    ).toBe("à régler par compensation sur le reversement RV-2026-000002");
    // N = 0: set off at approval, no transfer — never « réglé » or « payé »
    const none = settlementText({
      ...netted,
      due_date: null,
      payment_reference: {
        mode: "run",
        run_number: "RV-2026-000003",
        execution_date: "2026-11-10",
        transfer: false,
        amount_minor: "6000",
      },
    });
    expect(none).toBe(
      `compensée le 10/11/2026 avec vos encaissements (relevé RV-2026-000003, aucun virement) : ${money("6000", "EUR")}`,
    );
    expect(none).not.toMatch(/payé|réglé/i);
    // N = 0 that sets off only part of the invoice (the usual partial case for a one-mandate client): the remainder
    // and its date are stated, as the PDF and the statement do (review M2c-5 round 2, legal#4)
    const partial = settlementText({
      ...netted,
      due_date: "2026-12-10",
      payment_reference: {
        mode: "run",
        run_number: "RV-2026-000003",
        execution_date: "2026-11-10",
        transfer: false,
        amount_minor: "2000",
        remainder_minor: "4000",
        latest_date: "2026-12-10",
      },
    });
    expect(partial).toBe(
      `compensée le 10/11/2026 avec vos encaissements (relevé RV-2026-000003, aucun virement) : ${money("2000", "EUR")} ; le solde de ${money("4000", "EUR")} sur le prochain reversement, au plus tard le 10/12/2026`,
    );
    expect(partial).not.toMatch(/payé|réglé/i);
    // a payload without the reference but a date: the date is still stated
    expect(settlementText({ ...netted, due_date: "2026-12-10" })).toBe(
      "à régler par compensation sur un reversement, au plus tard le 10/12/2026 pour ce que le reversement ne compense pas",
    );
  });

  it("formats CSV amounts in French, from text minor units (no float)", () => {
    expect(csvAmount("123456789")).toBe("1 234 567,89");
    expect(csvAmount("-1")).toBe("-0,01");
    expect(csvAmount("0")).toBe("0,00");
    expect(csvAmount("9007199254740993")).toBe("90 071 992 547 409,93");
  });

  it("writes a CSV with a BOM, ';' and CRLF, quoting what needs it", () => {
    const out = csvFile(["a", "b"], [["x;y", 'he said "hi"'], [null, "z"]], new Set(["a", "b"]));
    expect(out).toBe('﻿a;b\r\n"x;y";"he said ""hi"""\r\n;z\r\n');
  });

  it("accepts a period of at most a year", () => {
    expect(exportPeriod("2026-01-01", "2026-12-31")).toEqual({ from: "2026-01-01", to: "2026-12-31" });
    expect(exportPeriod("2026-12-31", "2026-01-01")).toBeNull();
    expect(exportPeriod("2025-01-01", "2026-12-31")).toBeNull();
    expect(exportPeriod("2026-1-1", "2026-12-31")).toBeNull();
    expect(exportPeriod(null, "2026-12-31")).toBeNull();
  });
});

describe("CSV text cells are never formulas (review M2c-5 security#0 = tests-ui#6, K3)", () => {
  it("puts an apostrophe before a leading = + - @ TAB or CR, and only then", () => {
    expect(["=1+1", "+33", "-x", "@SUM(A1)", "\tx", "\rx"].map(neutraliseText)).toEqual([
      "'=1+1",
      "'+33",
      "'-x",
      "'@SUM(A1)",
      "'\tx",
      "'\rx",
    ]);
    expect(["Durand", " =1", "a=b", "", "'=déjà"].map(neutraliseText)).toEqual(["Durand", " =1", "a=b", "", "'=déjà"]);
  });

  it("neutralises the text columns it is given, then quotes; amounts and dates stay as they are", () => {
    const out = csvFile(
      ["client", "montant", "montant_centimes", "date", "piece"],
      [["=HYPERLINK(\"x\";\"y\")", "-12,34", "-1234", "2026-11-02", "\rRV"]],
      new Set(["client", "piece"]),
    );
    expect(out).toBe('﻿client;montant;montant_centimes;date;piece\r\n"\'=HYPERLINK(""x"";""y"")";-12,34;-1234;2026-11-02;"\'\rRV"\r\n');
  });

  it("refuses a text column that is not in the header (the list is explicit)", () => {
    expect(() => csvFile(["a"], [["x"]], new Set(["b"]))).toThrow(/not in the header/);
  });
});

describe("the client's statements read the run as it stands (review M2c-5 figures#1 = tests-ui#1, K7)", () => {
  it("words the live status, not the one frozen in the statement", () => {
    expect(statementRunView({ status: "approved", net_minor: 65601 })).toEqual({
      label: "Virement ordonné",
      tone: "neutral",
      net: "65601",
    });
    expect(statementRunView({ status: "sent", net_minor: "65601" }).label).toBe("Virement ordonné");
    expect(statementRunView({ status: "booked", net_minor: "65601" })).toEqual({
      label: "Virement débité de notre compte",
      tone: "ok",
      net: "65601",
    });
    expect(statementRunView({ status: "booked", net_minor: 0 }).label).toBe("Réglé par compensation, sans virement");
  });

  it("shows no amount to transfer for a cancelled run", () => {
    expect(statementRunView({ status: "cancelled", net_minor: "65601" })).toEqual({
      label: "Annulé avant son exécution",
      tone: "error",
      net: null,
    });
    expect(statementRunView(null)).toEqual({ label: "Statut indisponible", tone: "neutral", net: null });
  });
});

describe("what is owed today and the payout in flight (review M2c-5 tests-ui#5, K2)", () => {
  const eur = (m: string) => money(m, "EUR");

  it("says the in-flight gross is part of what is owed, and what it is made of", () => {
    const notes = inFlightNotes({
      owed: [
        {
          currency: "EUR",
          owed_minor: "80001",
          in_flight_gross_minor: "80001",
          in_flight_runs: [{ number: "RV-2026-000001", gross_minor: "80001", net_minor: "65601", commission_minor: "14400" }],
        },
      ],
      in_flight: [
        { number: "RV-2026-000001", status: "approved", currency: "EUR", net_minor: "65601", requested_execution_date: "2026-11-12" },
      ],
    });
    expect(notes.sentences).toEqual([
      `À reverser à ce jour : ${eur("80001")}, dont ${eur("80001")} compris dans le reversement RV-2026-000001 ordonné, exécution demandée le 12/11/2026 (${eur("65601")} à virer ; ${eur("14400")} de commission à compenser au débit du virement).`,
    ]);
    expect(notes.covered).toEqual(new Set(["RV-2026-000001"]));
    expect(notes.sentences.join(" ")).not.toMatch(/payé|réglé/i);
  });

  it("names a part owed beyond the payout, other set-offs and a refunded credit note", () => {
    const { sentences } = inFlightNotes({
      owed: [
        {
          currency: "EUR",
          owed_minor: "100000",
          in_flight_gross_minor: "90000",
          in_flight_runs: [
            { number: "RV-2026-000002", gross_minor: "50000", net_minor: "40000", commission_minor: "6000" },
            { number: "RV-2026-000003", gross_minor: "40000", net_minor: "42000", commission_minor: "0" },
          ],
        },
      ],
      in_flight: [],
    });
    expect(sentences).toEqual([
      `À reverser à ce jour : ${eur("100000")}, dont ${eur("90000")} compris dans les reversements ordonnés RV-2026-000002 (${eur("50000")} : ${eur("40000")} à virer ; ${eur("6000")} de commission et ${eur("4000")} d'autres sommes dues au cabinet à compenser au débit du virement) et RV-2026-000003 (${eur("40000")} : ${eur("42000")} à virer dont ${eur("2000")} de remboursement d'avoir).`,
    ]);
  });

  it("adds nothing without a payout in flight, or when the database does not say it", () => {
    expect(inFlightNotes({ owed: [{ currency: "EUR", owed_minor: "500" }], in_flight: [] }).sentences).toEqual([]);
    expect(
      inFlightNotes({
        owed: [{ currency: "EUR", owed_minor: "500", in_flight_gross_minor: "0", in_flight_runs: [] }],
        in_flight: [],
      }).sentences,
    ).toEqual([]);
    expect(inFlightNotes(null)).toEqual({ sentences: [], covered: new Set() });
    // amounts that are not text in minor units are never worded (the page's own in-flight note stays)
    const odd = inFlightNotes({
      owed: [
        {
          currency: "EUR",
          owed_minor: "80001",
          in_flight_gross_minor: "80001",
          in_flight_runs: [{ number: "RV-1", gross_minor: "80001", net_minor: "65601", commission_minor: null as unknown as string }],
        },
      ],
      in_flight: [],
    });
    expect(odd).toEqual({ sentences: [], covered: new Set() });
  });

  it("words the advances and the refunded credit note the database names, even in the same run (integration)", () => {
    // client_remittance_summary returns advance_minor and refund_minor: gross = net + commission + advances − refund.
    // An advance of 100,00 € and a refund of 30,00 € must both be named, never netted into « 70,00 € d'autres sommes ».
    const { sentences } = inFlightNotes({
      owed: [
        {
          currency: "EUR",
          owed_minor: "50000",
          in_flight_gross_minor: "50000",
          in_flight_runs: [
            {
              number: "RV-2026-000004",
              status: "approved",
              gross_minor: "50000",
              net_minor: "39000",
              commission_minor: "4000",
              advance_minor: "10000",
              refund_minor: "3000",
              requested_execution_date: "2026-11-20",
            },
          ],
        },
      ],
      in_flight: [],
    });
    expect(sentences).toEqual([
      `À reverser à ce jour : ${eur("50000")}, dont ${eur("50000")} compris dans le reversement RV-2026-000004 ordonné, exécution demandée le 20/11/2026 (${eur("39000")} à virer dont ${eur("3000")} de remboursement d'avoir ; ${eur("4000")} de commission et ${eur("10000")} d'avances du cabinet à compenser au débit du virement).`,
    ]);
    // amounts that do not add up are never worded
    expect(
      inFlightNotes({
        owed: [
          {
            currency: "EUR",
            owed_minor: "50000",
            in_flight_gross_minor: "50000",
            in_flight_runs: [
              { number: "RV-5", gross_minor: "50000", net_minor: "39000", commission_minor: "4000", advance_minor: "1", refund_minor: "0" },
            ],
          },
        ],
        in_flight: [],
      }).sentences,
    ).toEqual([]);
  });
});

describe("the client's lists page instead of stopping (review M2c-5 tests-ui#7)", () => {
  it("reads a page number and asks one row more to know whether older ones exist", () => {
    expect(listPage(undefined, 100)).toEqual({ page: 0, from: 0, to: 100 });
    expect(listPage("2", 100)).toEqual({ page: 2, from: 200, to: 300 });
    expect(listPage(["1", "5"], 200)).toEqual({ page: 1, from: 200, to: 400 });
    expect(listPage("-3", 100).page).toBe(0);
    expect(listPage("abc", 100).page).toBe(0);
    expect(listPage("1e9", 100).page).toBe(0);
  });

  it("keeps a page's rows and says when more follow", () => {
    expect(pageOf([1, 2, 3], 2)).toEqual({ rows: [1, 2], more: true });
    expect(pageOf([1, 2], 2)).toEqual({ rows: [1, 2], more: false });
    expect(pageOf(null, 2)).toEqual({ rows: [], more: false });
  });
});

describe("the run page waits only for a statement that will come (review M2c-5 perf#6 = tests-ui#3)", () => {
  it("polls while an approved run's statement is being drawn, a cancelled one's included", () => {
    expect(runStatementState({ status: "approved", approved_at: "2026-11-10T10:00:00Z" }, null)).toBe("pending");
    expect(runStatementState({ status: "cancelled", approved_at: "2026-11-10T10:00:00Z" }, null)).toBe("pending");
    expect(runStatementState({ status: "booked", approved_at: "2026-11-10T10:00:00Z" }, { number: "RV-1" })).toBe("drawn");
  });

  it("never waits for a draft, or for one discarded or cancelled before its approval", () => {
    expect(runStatementState({ status: "draft", approved_at: null }, null)).toBe("draft");
    expect(runStatementState({ status: "cancelled", approved_at: null }, null)).toBe("none");
  });
});
