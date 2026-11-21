import { describe, expect, it } from "vitest";
import { CHECK_LABEL, breachHeldHelp, checkLabel, checkOldestDays, checkSubjectLink } from "./debits";

/**
 * M2c-6b-3b part 2 (ADR-0014 « M2c-6b-3b part 2 »; COMPLIANCE CPCE-08): « remittance_breach_held », the nightly
 * checks' alert on a booked run whose R124-6 row is held — another transfer of its payout chain (the payout cancelled
 * out of a downloaded file, or its re-issue) may have paid the client on time, and the row waits until the paying
 * account's statements cover every business day in question and no line that may be that transfer's debit waits. The
 * texts say what is held and why, what ops do (import the missing statement, classify the line), and that the row is
 * written by the next check once that is done, if the lateness stands. The alert is an operational safeguard: no text
 * gives it a legal deadline of its own.
 */
const DETAILS_DAYS = {
  number: "REV-2026-0007",
  judged_on: "2026-11-12",
  earliest_latest_execution_date: "2026-11-06",
  uncovered_days: ["2026-11-03", "2026-11-04"],
  balance_break: false,
  waiting: [],
  bound_days: 5,
};
const DETAILS_LINE = {
  ...DETAILS_DAYS,
  uncovered_days: [],
  waiting: [
    {
      line_id: "11111111-1111-1111-1111-111111111111",
      booking_date: "2026-11-04",
      amount_minor: "164000",
      currency: "EUR",
      end_to_end_id: "RMT0A1B2C3D4E5F",
    },
  ],
};
// a legal deadline the law does not set for this alert (« sous N jours », « délai légal »)
const INVENTED = /délai légal|sous \d+ jours|dans les \d+ jours|jours calendaires/;

describe("remittance_breach_held (M2c-6b-3b part 2, CPCE-08)", () => {
  it("is labelled in French and says the deadline row is held, why, and what lifts it", () => {
    const l = CHECK_LABEL.remittance_breach_held;
    expect(l).toBeDefined();
    expect(l.label).toBe("Dépassement de délai non encore enregistré");
    // what is held, and why: another transfer of the run may have paid the client on time
    expect(l.help).toContain("art. R124-6 CPCE");
    expect(l.help).toContain("n'est pas encore enregistré");
    expect(l.help).toMatch(/autre virement émis pour ce reversement/);
    expect(l.help).toContain("a pu les payer à temps");
    // what ops do: import the missing statement, classify the line — then the next check records it, if it stands
    expect(l.help).toContain("importez les relevés manquants");
    expect(l.help).toContain("« Débits et retours »");
    expect(l.help).toContain("au prochain contrôle");
    expect(l.help).toContain("s'il est avéré");
    expect(l.help).toContain("l'alerte cesse");
    expect(l.help).not.toMatch(INVENTED);
    // review round 1 (dt-1): a statement counts for a day only once established after that day's end
    expect(l.help).toContain("établis après la fin des jours en cause");
    // review round 1 (dt-2): a possible debit holds the record while it may still be that transfer's — never « until
    // no line waits »: a line « Comptabiliser… » does not propose as that transfer stops holding it after some business
    // days, and the overrun is then recorded although the line still waits (« bloqué : débit possible non comptabilisé »)
    expect(l.help).not.toContain("n'attend plus");
    expect(l.help).toContain("ne retient plus l'enregistrement");
    expect(l.help).toContain(
      "une ligne que « Comptabiliser… » ne propose pas comme ce virement cesse de le retenir quelques jours ouvrés après sa date",
    );
  });

  it("never says a day's statement is missing when one is imported: it asks for one established after the day's end (dt-1)", () => {
    const h = breachHeldHelp(DETAILS_DAYS);
    // a statement produced during the day, or a CSV ending on it, is imported yet covers nothing of it
    // (private.statement_covers): the day is named as not covered, never as « to import » alone
    expect(h).not.toContain("Importez les relevés du compte de fonds de tiers des jours ouvrés suivants");
    expect(h).toContain(
      "Aucun relevé importé du compte de fonds de tiers ne couvre encore les jours ouvrés suivants : 03/11/2026, 04/11/2026.",
    );
    expect(h).toContain("Importez un relevé de ces jours établi par la banque après leur fin");
    expect(h).toContain("un relevé établi pendant l'un d'eux ne compte pas pour ce jour");
    expect(h).toContain("ni le dernier jour d'un export CSV");
    expect(h).not.toMatch(INVENTED);
  });

  it("names the business days no imported statement covers yet, and says to import them", () => {
    const h = breachHeldHelp(DETAILS_DAYS);
    expect(h).toContain("ne couvre encore les jours ouvrés suivants : 03/11/2026, 04/11/2026.");
    expect(h).toContain("Importez un relevé de ces jours");
    expect(h).not.toContain("Classez");
    expect(h).not.toMatch(INVENTED);
  });

  it("says a statement is missing between two imported ones when their balances do not follow", () => {
    const h = breachHeldHelp({ ...DETAILS_DAYS, uncovered_days: [], balance_break: true });
    expect(h).toContain("le solde d'ouverture de l'un ne reprend pas le solde de clôture du précédent");
    expect(h).toContain("importez le relevé manquant");
  });

  it("names the waiting line (its date, its amount, the transfer it may be) and says how to classify it", () => {
    const h = breachHeldHelp(DETAILS_LINE);
    // the amount as the page prints every amount (lib/money: narrow no-break space, no-break space before €)
    expect(h).toContain("la ligne du 04/11/2026 de 1 640,00 €");
    expect(h).toContain("qui peut être le débit du virement RMT0A1B2C3D4E5F");
    expect(h).toContain("« Débits et retours »");
    expect(h).toContain("« Comptabiliser… »");
    // Q14's bound (private.transfer_debit_bound_days), from the row's details: never a number the page invents
    expect(h).toContain("5 jours ouvrés après sa date");
    expect(h).toContain("« bloqué : débit possible non comptabilisé »");
    expect(h).not.toContain("Importez");
    expect(h).not.toMatch(INVENTED);
    expect(breachHeldHelp({ ...DETAILS_LINE, bound_days: 3 })).toContain("3 jours ouvrés après sa date");
  });

  it("words the instruction for each line when several wait, never « -la » after a list (tests-ui-4)", () => {
    const two = [
      { ...DETAILS_LINE.waiting[0], line_id: "l1", booking_date: "2026-11-03", amount_minor: "1000", end_to_end_id: "RMTX" },
      { ...DETAILS_LINE.waiting[0], line_id: "l2", booking_date: "2026-11-04", amount_minor: "1000", end_to_end_id: "RMTX" },
    ];
    const h = breachHeldHelp({ ...DETAILS_LINE, waiting: two, waiting_count: 2 });
    // (lib/money: a no-break space before €)
    expect(h).toContain("la ligne du 03/11/2026 de 10,00 €, qui peut être le débit du virement RMTX ; la ligne du 04/11/2026");
    expect(h).toContain(
      ": pour chacune, comptabilisez-la (« Comptabiliser… ») si c'est le débit du virement en cause, sinon classez-la pour ce qu'elle est.",
    );
    expect(h).not.toContain(": comptabilisez-la");
    expect(h).toContain("Une ligne que « Comptabiliser… » ne propose pas comme le virement en cause cesse de retenir");
    // one line named and others counted: several lines all the same
    const more = breachHeldHelp({ ...DETAILS_LINE, waiting_count: 3 });
    expect(more).toContain("et 2 autres lignes : pour chacune, comptabilisez-la");
    // one line alone: its own transfer
    const one = breachHeldHelp(DETAILS_LINE);
    expect(one).toContain(
      ": comptabilisez-la (« Comptabiliser… ») si c'est le débit de ce virement, sinon classez-la pour ce qu'elle est.",
    );
    expect(one).not.toContain("pour chacune");
    expect(one).toContain("Une ligne que « Comptabiliser… » ne propose pas comme ce virement cesse de retenir");
    // the bound's noun agrees with its number
    expect(breachHeldHelp({ ...DETAILS_LINE, bound_days: 1 })).toContain("1 jour ouvré après sa date");
  });

  it("writes the oldest age with its noun agreeing (tests-ui-5)", () => {
    expect(checkOldestDays(1)).toBe("le plus ancien : 1 jour");
    expect(checkOldestDays(0)).toBe("le plus ancien : 0 jour");
    expect(checkOldestDays(2)).toBe("le plus ancien : 2 jours");
    expect(checkOldestDays(31)).toBe("le plus ancien : 31 jours");
  });

  it("lists at most ten days and three lines, then how many more", () => {
    const days = Array.from({ length: 12 }, (_, k) => `2026-10-${String(k + 1).padStart(2, "0")}`);
    const h = breachHeldHelp({ ...DETAILS_DAYS, uncovered_days: days });
    expect(h).toContain("01/10/2026, 02/10/2026");
    expect(h).toContain("10/10/2026 et 2 autres.");
    expect(h).not.toContain("11/10/2026");
    const lines = Array.from({ length: 4 }, (_, k) => ({ ...DETAILS_LINE.waiting[0], line_id: `l${k}` }));
    const w = breachHeldHelp({ ...DETAILS_LINE, waiting: lines });
    expect(w.match(/la ligne du 04\/11\/2026/g)?.length).toBe(3);
    expect(w).toContain("et 1 autre ligne");
    // the row lists the first 31 days and 10 lines and counts them all (uncovered_count, waiting_count)
    const counted = breachHeldHelp({
      ...DETAILS_LINE,
      uncovered_days: days.slice(0, 10),
      uncovered_count: 40,
      waiting: lines.slice(0, 3),
      waiting_count: 12,
    });
    expect(counted).toContain("10/10/2026 et 30 autres.");
    expect(counted).toContain("et 9 autres lignes");
  });

  it("says the run is judged again when neither a day nor a line holds it any more (the facts moved meanwhile)", () => {
    const h = breachHeldHelp({ ...DETAILS_DAYS, uncovered_days: [] });
    expect(h).toContain("réexaminé au prochain contrôle");
  });

  it("is the same text whichever the switch, the row's details deciding (the alert is raised only for a chain)", () => {
    for (const on of [false, true]) {
      expect(checkLabel("remittance_breach_held", { cancellationAfterDownload: on, details: DETAILS_LINE })).toEqual({
        label: "Dépassement de délai non encore enregistré",
        help: breachHeldHelp(DETAILS_LINE),
      });
    }
    // without details (an older row): the label's own help
    expect(checkLabel("remittance_breach_held")).toEqual(CHECK_LABEL.remittance_breach_held);
    // the help with details starts with the label's own explanation
    expect(breachHeldHelp(DETAILS_DAYS).startsWith(CHECK_LABEL.remittance_breach_held.help)).toBe(true);
  });

  it("leads to the run", () => {
    expect(
      checkSubjectLink({ code: "remittance_breach_held", subject_type: "remittance_run", subject_id: "r-1" }),
    ).toBe("/backoffice/reversements/r-1");
  });
});
