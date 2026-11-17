// M2c-6b-2a (plan docs/design/m2c-6b-2-plan.md §2.4, §2.6, §7.1, §8.3): the job's two new reviews, the download's
// sweep re-check, the new alerts, and the S23 texts — while no screen books these lines, every text says what the
// code does: nothing is booked, Collectoo cannot book it yet, support is told.
import { describe, expect, it } from "vitest";
import { errorText } from "../boarding/forms";
import { holdLabel, refusalText } from "../remittance/transfers";
import { CHECK_LABEL, checkLabel, DEBIT_REVIEW, P0_DEBIT_REVIEWS, debitReviewRank } from "./debits";
import { OUR_TRANSFER_PAYMENT_NOTE } from "./matching";

describe("the job's reviews of a return it does not book (critic F1, L5; critic2 ML-3, CSO2-14)", () => {
  it("unplanned_payout_return names the payout and the sweep, books nothing and says to tell support", () => {
    const text = DEBIT_REVIEW.unplanned_payout_return;
    expect(text).toContain("reversement ou quote-part");
    expect(text).toContain("rien n'est comptabilisé automatiquement");
    expect(text).toContain("prévenez le support");
    expect(text).not.toContain("Virement revenu");
    expect(text).not.toContain("écran à venir");
  });
  it("return_debit_pending says the other debit is booked first, and to tell support", () => {
    const text = DEBIT_REVIEW.return_debit_pending;
    expect(text).toContain("figure sur un relevé sans être encore comptabilisé");
    expect(text).toContain("ce débit se comptabilise d'abord");
    expect(text).toContain("prévenez le support");
    expect(text).not.toContain("Virement revenu");
  });
  // review M2c-6b-2a (M1): a held copy of the debit decided a duplicate no longer counts, and the decision queues the
  // job that takes the return up again (private.transfer_late_lines, public.resolve_duplicate); while it is held the
  // label says to decide it first, never to book it
  it("return_debit_pending says a held copy is decided first in « Doublons possibles », never booked", () => {
    const text = DEBIT_REVIEW.return_debit_pending;
    expect(text).toContain(
      "Si ce débit attend dans « Doublons possibles », décidez-le d'abord : reconnu comme doublon, il ne compte plus et le retour est repris automatiquement.",
    );
    expect(text).not.toContain("Ce débit se comptabilise d'abord");
  });
  it("neither is a P0 of « À classer » (the money did not leave twice: it came back)", () => {
    expect(debitReviewRank("unplanned_payout_return")).toBe(1);
    expect(debitReviewRank("return_debit_pending")).toBe(1);
  });
  it("the M2b pass's own reason on our lines has a label that promises no screen (review M2c-6b-2a T6)", () => {
    const text = DEBIT_REVIEW.own_transfer_line;
    expect(text).toContain("nos propres virements");
    expect(text).toContain("rien n'est comptabilisé automatiquement");
    expect(text).toContain("Collectoo ne peut pas encore la comptabiliser");
    expect(text).toContain("prévenez le support");
    expect(text).not.toContain("écran à venir");
  });
});

describe("the sweep re-checked at the first download (critic CSO-2, F10; critic2 CSO2-4)", () => {
  it("sweep_exceeds_share says why the file is replaced and that the share is recomputed", () => {
    expect(holdLabel("sweep_exceeds_share")).toBe(
      "La quote-part du cabinet de ce fichier dépasse ce qui lui revient maintenant (une avance, des frais ou une couverture ont été comptabilisés depuis sa génération) : le fichier est remplacé, la quote-part sera recalculée.",
    );
  });
  it("file_blocked with only the sweep blocked: the payouts go back in, their deadline still runs", () => {
    const text = refusalText("file_blocked", [{ transfer_id: "00000000-0000-0000-0000-000000000001", reason: "sweep_exceeds_share" }]);
    expect(text).toBe(
      "Le fichier n'a pas été servi et il est remplacé : seule la quote-part du cabinet a changé depuis sa génération. Régénérez-le maintenant : les reversements qu'il contenait y reviennent (leur date limite court toujours).",
    );
    expect(text).not.toContain("restent hors du fichier");
  });
  it("file_blocked with a payout blocked too, or with nothing listed: today's text", () => {
    const today =
      "Des virements de ce fichier ne passent plus les contrôles depuis sa génération : le fichier n'a pas été servi et il est remplacé. Régénérez-le ; ces virements restent hors du fichier tant que leur motif demeure.";
    expect(
      refusalText("file_blocked", [
        { transfer_id: "00000000-0000-0000-0000-000000000001", reason: "sweep_exceeds_share" },
        { transfer_id: "00000000-0000-0000-0000-000000000002", reason: "late_reason_required" },
      ]),
    ).toBe(today);
    expect(refusalText("file_blocked", [])).toBe(today);
    expect(refusalText("file_blocked")).toBe(today);
  });
});

describe("the new alerts (critic L10, L14)", () => {
  it("transfer_unknown names both directions", () => {
    expect(checkLabel("transfer_unknown").help).toBe(
      "Ligne (débit ou crédit) portant une référence de virement du cabinet (RMT, SWP) ou un lot que Collectoo ne connaît pas : vérifiez dans la banque.",
    );
    expect(P0_DEBIT_REVIEWS.has("transfer_unknown")).toBe(true);
  });
  it("own_transfer_payment says not to assign nor refund it, and to tell support", () => {
    expect(checkLabel("own_transfer_payment").help).toBe(
      "Paiement créé à partir d'un de nos virements revenus (il porte la référence d'un reversement, d'une quote-part du cabinet ou d'un lot de nos fichiers) : ces sommes ne sont reversées à personne tant qu'il n'est pas traité. Ne l'affectez pas, ne le remboursez pas, prévenez le support.",
    );
  });
  it("double_payout_open says the recovery is not handled in Collectoo yet", () => {
    expect(checkLabel("double_payout_open").help).toBe(
      "Avance du cabinet après un virement exécuté hors reversement : à récupérer auprès du client — ce recouvrement n'est pas encore géré dans Collectoo.",
    );
  });
  it("every new check has a label of its own", () => {
    for (const code of ["transfer_unknown", "own_transfer_payment", "double_payout_open"])
      expect(CHECK_LABEL[code]?.label.length ?? 0).toBeGreaterThan(0);
  });
});

describe("the S23 texts (critic L10): no screen promised, Collectoo cannot book it yet", () => {
  const texts = {
    payment: errorText("payment_own_transfer_line"),
    duplicate: errorText("duplicate_own_transfer_line"),
    note: OUR_TRANSFER_PAYMENT_NOTE,
  };
  it.each(Object.entries(texts))("%s says « ne peut pas encore » and promises no screen", (_name, text) => {
    expect(text).toMatch(/ne (peut|peuvent) pas encore|ni encore comptabilisée/);
    expect(text).not.toContain("écran à venir");
    expect(text).toMatch(/prévenez le support/i);
  });
  it("the duplicate stays in « Doublons possibles »", () => {
    expect(texts.duplicate).toContain("elle reste dans « Doublons possibles »");
  });
});
