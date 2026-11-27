import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { clientPaymentRefusal } from "@/lib/remittance/settlements";
import { topUpErrorCode } from "@/lib/remittance/top-ups";
import {
  CHECK_LABEL,
  DEBIT_REVIEW,
  LABEL_REFERENCE_DEBTOR_NOTE,
  LABEL_REFERENCE_EXIT_LABEL,
  LABEL_REFERENCE_TOP_UP_SUPPORT,
  LABEL_REFERENCE_WAITING_ANY_TAIL,
  LABEL_REFERENCE_WAITING_NOTE,
  LABEL_REFERENCE_WAITING_TAIL,
  LABEL_REFERENCE_WAITING_TOP_UP_TAIL,
  decisionLabel,
  labelReferenceDebtorEffect,
  labelReferenceExits,
  labelReferenceText,
  labelReferenceTopUpEffect,
  labelReferenceWaiting,
  releaseEffect,
} from "./debits";
import { TRANSFER_LINE_REFUSAL, transferLineEffects, transferLineRefusalText } from "./transfer-lines";

/**
 * M2c-7e-3 (plan docs/design/m2c-7-plan.md §7.3, §7.4; ADR-0014 « M2c-7e-3 »): a credit held because its CSV label cites
 * one of our transfers leaves « À classer » by one of its exits — « Oui, c'est son retour » (a payout or a sweep cited),
 * « Règlement du client », « Paiement d'un débiteur » and, for our own top-up's credit with no sending account at its
 * amount, « C'est cet approvisionnement » (founder Q15's added question, default a) —; 7e-2's texts that said no screen
 * classifies the line are true of 7e-3.
 */
const row = (o: Partial<Record<string, unknown>> = {}) => ({
  direction: "credit",
  kind: "label_reference",
  amount_minor: "100000",
  counterparty_iban_end: "0185",
  reference_from_label: "RMT0123456789AB",
  label_transfer: {
    transfer_id: "t1",
    kind: "payout",
    status: "booked",
    amount_minor: "100000",
    currency: "EUR",
    run_number: "RV-2026-000012",
  },
  ...o,
});
const top = (o: Partial<Record<string, unknown>> = {}, t: Partial<Record<string, unknown>> = {}) =>
  row({
    amount_minor: "4700",
    counterparty_iban_end: null,
    reference_from_label: "TOP0123456789AD",
    label_transfer: { transfer_id: "t2", kind: "top_up", status: "ordered", amount_minor: "4700", currency: "EUR", ...t },
    ...o,
  });
const n = (text: string) => text.replace(/ | /g, " ");

describe("the exits of a credit citing our reference (label_reference)", () => {
  it("offers the return of a payout or a sweep it cites, the client's and a debtor's payment", () => {
    expect(labelReferenceExits(row())).toEqual(["return", "client", "debtor"]);
    expect(labelReferenceExits(row({ label_transfer: { kind: "sweep", amount_minor: "5000" } }))).toEqual([
      "return",
      "client",
      "debtor",
    ]);
    // a TOP has no return exit; with an IBAN, never the top-up itself
    expect(labelReferenceExits(top({ counterparty_iban_end: "0185" }))).toEqual(["client", "debtor"]);
    // no candidate read: the client's and a debtor's payment only
    expect(labelReferenceExits(row({ label_transfer: null, reference_from_label: null }))).toEqual(["client", "debtor"]);
    // any other kind: none of these
    expect(labelReferenceExits(row({ kind: "debtor_credit" }))).toEqual([]);
    expect(labelReferenceExits(row({ direction: "debit" }))).toEqual([]);
    expect(LABEL_REFERENCE_EXIT_LABEL).toEqual({
      return: "Oui, c'est son retour",
      client: "Règlement du client",
      debtor: "Paiement d'un débiteur",
      top_up: "C'est cet approvisionnement",
    });
  });

  it("offers « C'est cet approvisionnement » only for our awaited top-up, at its amount, with no sending account", () => {
    expect(labelReferenceExits(top())).toEqual(["client", "debtor", "top_up"]);
    expect(labelReferenceExits(top({}, { status: "in_file" }))).toEqual(["client", "debtor", "top_up"]);
    for (const status of ["cancelled", "booked", "returned", null])
      expect(labelReferenceExits(top({}, { status })), String(status)).toEqual(["client", "debtor"]);
    expect(labelReferenceExits(top({ amount_minor: "4701" }))).toEqual(["client", "debtor"]);
    expect(labelReferenceExits(top({}, { transfer_id: null }))).toEqual(["client", "debtor"]);
  });

  it("words each exit's effect, true of what the command does", () => {
    expect(n(labelReferenceDebtorEffect({ amount: "200,00 €", dateFr: "26/11/2026" }))).toBe(
      "Le crédit de 200,00 € devient un paiement à affecter ; notre référence citée dans le libellé est ignorée. Il est comptabilisé sur le compte de fonds de tiers au 26/11/2026 (date de la ligne) et attend dans « Paiements à traiter » d'être affecté au dossier du débiteur ; son payeur est le titulaire du compte qui l'a envoyé (« Versement relayé par le client » s'il vient du compte de reversement confirmé d'un client). Le motif est conservé : indiquez ce qui montre que c'est le paiement d'un débiteur.",
    );
    expect(n(labelReferenceTopUpEffect({ amount: "47,00 €", reference: "TOP0123456789AD" }))).toBe(
      "Le crédit de 47,00 € sera comptabilisé comme l'approvisionnement TOP0123456789AD du compte dédié par le cabinet, venu du compte propre : Collectoo ne l'attend plus. À ne choisir que si ce crédit est bien cet approvisionnement (son libellé le cite, le relevé ne donne pas le compte émetteur).",
    );
    expect(decisionLabel("relayed_payment", "label_reference")).toBe(LABEL_REFERENCE_DEBTOR_NOTE);
    expect(LABEL_REFERENCE_DEBTOR_NOTE).toBe("Paiement d'un débiteur citant notre référence (vérifié par l'équipe)");
  });

  it("words the refusals of the return, the client's payment and the top-up (plan §7.4)", () => {
    expect(TRANSFER_LINE_REFUSAL.label_reference_transfer).toBe(
      "Seul le virement cité dans le libellé peut revenir sur cette ligne.",
    );
    expect(transferLineRefusalText("label_reference_amount", null)).toBe(
      "Le montant n'est pas exactement celui du virement cité : ce n'est pas son retour. Choisissez « Règlement du client » ou « Paiement d'un débiteur ».",
    );
    expect(clientPaymentRefusal("client payment refused: client_required", null, "line")).toBe(
      "Indiquez le client qui rembourse : le compte émetteur n'est pas un compte de reversement confirmé.",
    );
    expect(clientPaymentRefusal("client payment refused: client_mismatch", null, "line")).toBe(
      "Ce crédit vient du compte de reversement confirmé d'un autre client.",
    );
    expect(clientPaymentRefusal("client payment refused: client_unknown", null, "line")).toBe(
      "Ce client n'est pas un client du cabinet.",
    );
    expect(topUpErrorCode("top-up credit refused: label_reference_transfer")).toBe("top_up_credit_not_cited");
    expect(errorText("top_up_credit_not_cited")).toBe(
      "Seul l'approvisionnement cité dans le libellé peut être rattaché à cette ligne.",
    );
  });

  it("says, on the return's sheet, that ops confirm what the label cites (never the bank's own return)", () => {
    const options = {
      class: "L",
      kind: "label_reference",
      direction: "credit",
      amount_minor: "100000",
      booking_date: "2026-11-26",
      charges_minor: null,
      counterparty_iban_end: "0185",
      unsplit_ours: null,
      proposals: [],
      members: null,
      member_count: null,
      refusal: null,
      refusal_detail: null,
      pending_line_id: null,
      pending_held: false,
    };
    const proposal = {
      action: "returned",
      request: [{ kind: "payout_returned", transfer_id: "t1", amount: "100000" }],
      parts: [],
      preview: {
        ok: true,
        why: null,
        detail: null,
        parts: [
          { kind: "payout_returned", transfer_id: "t1", amount_minor: "100000", run_number: "RV-2026-000012" },
        ],
        drafts: [],
        supersedes_file: null,
        expected_text: "x",
      },
    };
    const effects = transferLineEffects(options as never, proposal as never, "EUR");
    expect(effects[0]).toBe(
      "Le libellé de ce crédit cite ce virement du cabinet, à exactement son montant : vous confirmez que c'est lui qui revient. Il est comptabilisé comme revenu, comme lorsque la banque signale un retour.",
    );
    expect(effects.join(" ")).not.toContain("La banque du bénéficiaire a renvoyé");
  });
});

describe("7e-2's texts, true once the exits exist (item 4)", () => {
  it("no longer says that no screen classifies the line", () => {
    for (const text of [
      DEBIT_REVIEW.label_reference,
      LABEL_REFERENCE_WAITING_NOTE,
      LABEL_REFERENCE_WAITING_TAIL,
      LABEL_REFERENCE_WAITING_TOP_UP_TAIL,
      LABEL_REFERENCE_WAITING_ANY_TAIL,
      CHECK_LABEL.label_reference_waiting.help,
      errorText("label_reference_line"),
      errorText("label_reference_top_up_line"),
      releaseEffect({ direction: "credit", heldKind: "label_reference", amount: "1 000,00 €" }),
      labelReferenceText(row()),
      labelReferenceText(top()),
    ]) {
      expect(text).not.toContain("ne permet pas encore");
      expect(text).not.toContain("Aucun écran ne permet");
      expect(text).not.toContain("question Q15");
    }
    expect(LABEL_REFERENCE_WAITING_TAIL).toBe(
      "Rien n'est comptabilisé tant que la ligne n'est pas classée : retour de ce virement, règlement du client ou paiement d'un débiteur. Classez-la dans « Débits et retours », onglet « À classer ».",
    );
    expect(LABEL_REFERENCE_WAITING_TOP_UP_TAIL).toBe(
      "Rien n'est comptabilisé tant que la ligne n'est pas classée : règlement du client ou paiement d'un débiteur (ou, sans compte émetteur et du même montant, cet approvisionnement). Classez-la dans l'onglet « À classer » des débits (Encaissements).",
    );
    // a top-up has no return (7e-2's pin): not even the page's name « Débits et retours »
    expect(LABEL_REFERENCE_WAITING_TOP_UP_TAIL).not.toContain("retour");
    expect(errorText("label_reference_line")).toBe(
      "Le libellé cite l'un de nos virements : cette ligne ne se lie à aucun paiement et ne se classe pas sans comptabiliser. Classez-la avec « Oui, c'est son retour », « Règlement du client » ou « Paiement d'un débiteur ».",
    );
    expect(errorText("label_reference_top_up_line")).toBe(
      "Le libellé cite l'un de nos approvisionnements : cette ligne ne se lie à aucun paiement et ne se classe pas sans comptabiliser. Classez-la avec « Règlement du client » ou « Paiement d'un débiteur » (ou, sans compte émetteur et du même montant, « C'est cet approvisionnement »).",
    );
    expect(errorText("label_reference_top_up_line")).not.toContain("retour");
  });

  it("points to « C'est cet approvisionnement » only while that top-up is awaited", () => {
    expect(LABEL_REFERENCE_TOP_UP_SUPPORT).toBe(
      "S'il s'agit de cet approvisionnement, choisissez « C'est cet approvisionnement » : Collectoo l'attend encore.",
    );
    expect(labelReferenceText(top())).toContain(LABEL_REFERENCE_TOP_UP_SUPPORT);
    for (const status of ["cancelled", "booked", null])
      expect(labelReferenceText(top({}, { status })), String(status)).not.toContain("C'est cet approvisionnement");
    expect(labelReferenceText(top({ counterparty_iban_end: "0185" }))).not.toContain("C'est cet approvisionnement");
  });

  it("keeps « Contrôles »' classes by the candidate's kind", () => {
    expect(labelReferenceWaiting({ candidate_kind: "top_up", reference_from_label: "TOP0123456789AD" }).help).toBe(
      `Une ligne du relevé cite notre approvisionnement TOP0123456789AD dans son libellé. ${LABEL_REFERENCE_WAITING_TOP_UP_TAIL}`,
    );
    expect(labelReferenceWaiting({ candidate_kind: "sweep", reference_from_label: "SWP0123456789AB" }).help).toBe(
      `Une ligne du relevé cite notre référence SWP0123456789AB dans son libellé. ${LABEL_REFERENCE_WAITING_TAIL}`,
    );
  });
});
