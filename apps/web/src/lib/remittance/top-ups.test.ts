import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { CHECK_LABEL, DEBIT_REVIEW, checkLabel, checkLinkLabel, checkSubjectLink } from "@/lib/payments/debits";
import { holdLabel, transferErrorCode } from "@/lib/remittance/transfers";
import {
  CANCEL_TOP_UP_FILE_EFFECT,
  GENERATE_TOP_UP_FILE_EFFECT,
  TOP_UP_ID,
  TOP_UP_SECTION_ANCHOR,
  TOP_UP_SECTION_NOTE,
  TOP_UP_SECTION_TITLE,
  neededLine,
  offersTopUpLink,
  orderedBy,
  parseTopUpCreditOptions,
  periodLine,
  topUpErrorCode,
  topUpOptionLabel,
} from "@/lib/remittance/top-ups";

/** Whatever spaces Intl puts in a French amount (narrow no-break, no-break), as plain spaces. */
const plain = (s: string) => s.replace(/\s/g, " ");

// M2c-7e-1 (plan docs/design/m2c-7-plan.md §7.1, §7.2, §7.4)
describe("« Approvisionnements du compte dédié » (plan §7.4)", () => {
  it("is the section « Réapprovisionner » opens", () => {
    expect(TOP_UP_SECTION_TITLE).toBe("Approvisionnements du compte dédié");
    expect(checkSubjectLink({ code: "servicer_shortfall", subject_type: "organization", subject_id: "x" })).toBe(
      `/backoffice/reversements/virements#${TOP_UP_SECTION_ANCHOR}`,
    );
    expect(checkLinkLabel("servicer_shortfall")).toBe("Réapprovisionner");
    expect(checkSubjectLink({ code: "top_up_order_failed", subject_type: "organization", subject_id: "x" })).toBe(
      "/backoffice/reversements/virements#approvisionnements",
    );
    // no own account chosen: where it is chosen
    expect(checkSubjectLink({ code: "top_up_account_missing", subject_type: "organization", subject_id: "x" })).toBe(
      "/backoffice/parametres/facturation",
    );
    expect(checkLinkLabel("transfer_not_filed")).toBe("Ouvrir");
  });

  it("says who ordered a top-up", () => {
    expect(orderedBy({ automatic: true, ordered_by: null })).toBe("commandé automatiquement");
    expect(orderedBy({ automatic: false, ordered_by: "Ops" })).toBe("commandé par Ops");
  });

  it("says what is still to order, from the database's amount (never computed here)", () => {
    const own = { id: "a", label: "Compte propre", iban_last4: "0143" };
    // review round 2: what is owed with the sweeps in flight (design §13 #4's Σ4679 + sweeps ordered or in a file)
    const need = (owed: string, withSweeps: string, needed: string, surplus: string, own_account: typeof own | null) =>
      plain(
        neededLine({
          currency: "EUR",
          owed_minor: owed,
          owed_with_sweeps_minor: withSweeps,
          needed_minor: needed,
          surplus_minor: surplus,
          own_account,
        }),
      );
    // owed and covered by the orders
    expect(need("5000", "5000", "0", "0", own)).toBe(
      "Rien à approvisionner en EUR : les approvisionnements commandés couvrent ce que le cabinet doit.",
    );
    expect(need("5000", "5000", "5000", "0", own)).toBe("Encore à commander : 50,00 € (Collectoo le commande à la prochaine heure).");
    // review round 1 (MONEY-BANK-5, TUI-1): no own account chosen — the hourly job orders nothing, and says so
    expect(need("5000", "5000", "5000", "0", null)).toBe(
      "Encore à commander : 50,00 €. Aucun compte propre n'est choisi dans Paramètres › Facturation : Collectoo ne peut pas le commander ; approvisionnez le compte dédié à la main depuis le compte propre, ou choisissez le compte propre.",
    );
    expect(need("5000", "5000", "5000", "0", null)).not.toContain("prochaine heure");
    // review round 1 (TUI-7): nothing owed, nothing ordered — never « les approvisionnements commandés couvrent »
    expect(need("0", "0", "0", "0", own)).toBe("Le cabinet ne doit rien au compte dédié en EUR.");
    expect(need("-36000", "-36000", "0", "0", own)).toBe("Le cabinet ne doit rien au compte dédié en EUR.");
    // review round 2 (needed-line-sweep-in-flight, 047a n4): Σ4679 −160,00 while a sweep of 360,00 is in a file and
    // 200,00 is ordered — the cabinet owes 200,00 once the sweep is executed: the orders cover it, it is not « rien »
    expect(need("-16000", "20000", "0", "0", own)).toBe(
      "Rien à approvisionner en EUR : les approvisionnements commandés couvrent ce que le cabinet doit.",
    );
    // the servicer's share on 4679 already in a sweep, nothing else owed: nothing owed once it is executed
    expect(need("-36000", "0", "0", "0", own)).toBe("Le cabinet ne doit rien au compte dédié en EUR.");
    // the same advance not ordered yet: still to order (needed > 0 only when owed with the sweeps)
    expect(need("-16000", "20000", "20000", "0", own)).toBe(
      "Encore à commander : 200,00 € (Collectoo le commande à la prochaine heure).",
    );
    // review round 1 (TUI-2): an order left beyond what is owed (a cancelled top-up's late credit booked)
    expect(need("0", "0", "0", "1500", own)).toBe(
      "Le cabinet ne doit rien au compte dédié en EUR. Les approvisionnements encore à exécuter dépassent de 15,00 € ce qu'il doit : annulez ceux qui ne sont pas exécutés (« Annuler ») ; exécutés, le surplus revient au cabinet avec la prochaine quote-part.",
    );
  });

  it("states the cancellation's effect as the code does it (review round 1, TUI-2)", () => {
    expect(CANCEL_TOP_UP_FILE_EFFECT).toBe(
      "Les approvisionnements non comptabilisés de ce fichier sont annulés ; Collectoo recommande ce qui reste dû dans l'heure. Si la banque exécute quand même le fichier, la somme arrive sur le compte dédié : comptabilisez-la comme approvisionnement (« Débits et retours ») ; elle règle ce que le cabinet doit. Annulez alors l'approvisionnement recommandé entre-temps s'il n'est pas exécuté (« Annuler ») ; sinon le surplus revient au cabinet avec la prochaine quote-part.",
    );
    expect(CANCEL_TOP_UP_FILE_EFFECT).not.toContain("elle revient au cabinet");
  });

  it("warns that the file takes every top-up still to execute (review round 1, MONEY-BANK-6)", () => {
    const warning =
      "Le fichier reprend tous les approvisionnements à exécuter de ce compte propre dont le crédit n'est pas encore sur un relevé : si l'un d'eux a déjà été saisi à la main dans la banque, attendez son crédit avant de générer le fichier, ou il serait exécuté deux fois.";
    expect(GENERATE_TOP_UP_FILE_EFFECT).toContain(warning);
    expect(TOP_UP_SECTION_NOTE).toContain(warning);
    expect(TOP_UP_SECTION_NOTE).toContain("choisi dans Paramètres › Facturation");
  });

  it("names a refused download of an own-account file", () => {
    expect(holdLabel("transfer_cancelled")).toMatch(/annulé depuis la génération/);
    expect(holdLabel("top_up_booked")).toMatch(/déjà comptabilisé sur le compte dédié/);
    // review round 1 (MONEY-BANK-2): its credit on a statement, not booked yet
    expect(holdLabel("top_up_credited")).toBe(
      "Le crédit de cet approvisionnement est déjà sur un relevé du compte dédié : la banque l'a exécuté. Le fichier est remplacé ; comptabilisez ce crédit (« Débits et retours ») : aucun fichier ne le reprend d'ici là",
    );
  });
});

describe("« Périodes où le cabinet devait de l'argent au compte dédié » (plan §7.4)", () => {
  it("reads as the plan's example, in Paris time", () => {
    expect(
      plain(periodLine({ opened_at: "2026-11-12T13:37:00Z", closed_at: "2026-11-13T09:37:00Z", peak_minor: "200000", currency: "EUR" })),
    ).toBe("Du 12/11/2026 14:37 au 13/11/2026 10:37 — jusqu'à 2 000,00 €");
    expect(plain(periodLine({ opened_at: "2026-11-12T13:37:00Z", closed_at: null, peak_minor: "1", currency: "EUR" }))).toBe(
      "Depuis le 12/11/2026 14:37 (en cours) — jusqu'à 0,01 €",
    );
  });
});

describe("« Rattacher à TOP… » ([check 1] gap 12)", () => {
  it("is offered beside the top-up on an own credit with no TOP id only", () => {
    expect(offersTopUpLink(true, null)).toBe(true);
    expect(offersTopUpLink(true, "NOTPROVIDED")).toBe(true);
    expect(offersTopUpLink(true, "TOP0123456789AB")).toBe(false);
    expect(offersTopUpLink(false, null)).toBe(false);
    expect(TOP_UP_ID.test("TOP0123456789ab")).toBe(false);
  });

  it("lists the open top-ups as the database gives them", () => {
    expect(parseTopUpCreditOptions(null)).toBeNull();
    expect(parseTopUpCreditOptions({ top_ups: "x" })).toBeNull();
    const [o] =
      parseTopUpCreditOptions({
        top_ups: [
          {
            transfer_id: "t",
            end_to_end_id: "TOP0123456789AB",
            amount_minor: "20000",
            currency: "EUR",
            status: "in_file",
            created_at: "2026-11-12T13:37:00Z",
            automatic: true,
            file_number: "TF-2026-000003",
            debtor_label: "Compte propre",
            debtor_iban_last4: "0129",
          },
        ],
      }) ?? [];
    // review round 1 (MONEY-BANK-1): the own account it is ordered from (the credit's own)
    expect(plain(topUpOptionLabel(o))).toBe(
      "TOP0123456789AB — 200,00 € · depuis Compte propre ···0129 · commandé automatiquement le 12/11/2026 14:37 · dans le fichier TF-2026-000003",
    );
  });
});

describe("the refusals (plan §7.4): a code each, never the database's text", () => {
  it.each([
    ["top-up file refused: not_an_own_account", "top_up_file_not_own", "Ce compte n'est pas un compte propre actif du cabinet."],
    ["top-up file refused: not_eur", "top_up_file_not_eur", "Seuls les virements en euros sont pris en charge."],
    ["top-up file refused: nothing_to_file", "top_up_nothing_to_file", "Aucun approvisionnement à mettre dans un fichier."],
    ["top-up file refused: nothing_to_cancel", "top_up_nothing_to_cancel", "Ce fichier n'a plus d'approvisionnement à annuler."],
    [
      "top-up file refused: not_a_top_up_file",
      "top_up_not_a_top_up_file",
      "Ce fichier n'est pas un fichier d'approvisionnement : utilisez l'annulation des reversements.",
    ],
    ["top-up credit refused: not_an_own_credit", "top_up_credit_not_own", null],
    ["top-up credit refused: line_booked", "top_up_credit_booked", null],
    ["top-up credit refused: carries_top_up_id", "top_up_credit_carries_id", null],
    ["top-up credit refused: top_up_not_open", "top_up_not_open", null],
    ["top-up credit refused: amount_differs", "top_up_credit_amount", null],
    // review round 1 (MONEY-BANK-1): the credit came from another own account than the top-up's
    [
      "top-up credit refused: not_its_own_account",
      "top_up_credit_other_account",
      "Ce crédit ne vient pas du compte propre dont part cet approvisionnement.",
    ],
    ["bank booking refused: not_its_own_account", "top_up_credit_other_account", null],
    ["bank booking refused: top_up_cancelled_credit", "top_up_not_open", null],
    ["the top-up is no longer pending", "top_up_not_pending", "Cet approvisionnement n'est plus en attente (comptabilisé ou annulé)."],
    ["not allowed", "not_allowed", null],
  ] as const)("%s → %s", (message, code, text) => {
    expect(topUpErrorCode(message)).toBe(code);
    const words = errorText(code);
    expect(words).not.toBe(code);
    if (text) expect(words).toBe(text);
  });

  it("an unknown message stays unknown", () => {
    expect(topUpErrorCode("boom")).toBe("unknown");
  });

  it("« Annuler » of the payout files refuses an own-account file (review round 1, CC-2)", () => {
    const code = transferErrorCode("transfer file refused: not_a_payout_file");
    expect(code).toBe("transfer_not_a_payout_file");
    expect(errorText(code)).toBe(
      "Ce fichier est un fichier d'approvisionnement du compte propre : annulez-le par « Annuler le fichier » (« Virements », Approvisionnements du compte dédié).",
    );
  });
});

describe("the nightly checks and reviews of 7e-1 (plan §7.1, §7.4)", () => {
  it("words the new alerts and the shortfall help", () => {
    // review round 1 (TUI-1): « choisi » — an own account may exist and not be the one of « Facturation »
    expect(CHECK_LABEL.top_up_account_missing.help).toBe(
      "Le cabinet doit de l'argent au compte dédié mais aucun compte propre n'est choisi (Paramètres › Facturation) : Collectoo ne peut commander aucun approvisionnement. Choisissez le compte propre, ou approvisionnez le compte dédié à la main depuis le compte propre.",
    );
    expect(CHECK_LABEL.top_up_order_failed.label).toBeTruthy();
    // review round 1 (MONEY-BANK-4): the job not running is said too
    expect(CHECK_LABEL.top_up_order_failed.help).toContain("aucun passage depuis plus de trois heures");
    expect(CHECK_LABEL.servicer_shortfall.help).toContain(
      "Collectoo commande un approvisionnement chaque heure (référence TOP…, page Virements) : exécutez-le depuis le compte propre, à la main ou par le fichier.",
    );
  });

  it("never says the hourly job orders when no own account is chosen (review round 1, TUI-1)", () => {
    const none = checkLabel("servicer_shortfall", { noOwnAccount: true });
    expect(none.label).toBe(CHECK_LABEL.servicer_shortfall.label);
    expect(none.help).toBe(
      // M2c-7f-1 (H2, R3): the quotes-parts in flight counted, as the hourly order counts them
      "Le cabinet doit de l'argent au compte dédié (avances, frais bancaires, pertes), en comptant ses quotes-parts en cours de virement vers le compte propre, au-delà des approvisionnements demandés. Aucun compte propre n'est choisi (Paramètres › Facturation) : Collectoo ne peut pas le commander. Approvisionnez le compte dédié à la main depuis le compte propre, ou choisissez le compte propre.",
    );
    expect(none.help).not.toContain("chaque heure");
    expect(checkLabel("servicer_shortfall", { noOwnAccount: false })).toEqual(CHECK_LABEL.servicer_shortfall);
  });

  it("gives top_up_pending its exits, both of them followable (gap 12; review round 1, TUI-8)", () => {
    expect(CHECK_LABEL.top_up_pending.help).toContain(
      "Si son crédit est arrivé sans la référence TOP et n'est pas encore comptabilisé, rattachez-le à cet approvisionnement (« Rattacher à TOP… » sur la ligne) ; s'il a déjà été comptabilisé sans elle, annulez cet approvisionnement (« Annuler ») : sinon Collectoo croit l'approvisionnement encore attendu et commande trop peu.",
    );
    expect(CHECK_LABEL.top_up_pending.help).not.toContain("a été comptabilisé sans elle, rattachez-le");
  });

  it("words the review of a cancelled top-up executed after all as the code books it (review round 1, TUI-2)", () => {
    expect(DEBIT_REVIEW.top_up_cancelled_credit).toBe(
      "Approvisionnement annulé puis exécuté par la banque : c'est l'argent du cabinet. Comptabilisez-le comme approvisionnement : il règle ce que le cabinet doit au compte dédié. Si Collectoo a recommandé cet approvisionnement entre-temps, annulez la nouvelle commande (« Virements », « Annuler ») si elle n'est pas exécutée ; sinon le surplus revient au cabinet avec la prochaine quote-part.",
    );
  });
});
