import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  type ErrorCode,
  FILE_TRANSFER_NOT_EXECUTED,
  FILE_TRANSFER_NOT_EXECUTED_ON,
  PAYOUT_NOT_EXECUTED,
  PAYOUT_NOT_EXECUTED_ON,
  REFUND_NOT_EXECUTED,
  REFUND_NOT_EXECUTED_ON,
  errorText,
} from "@/lib/boarding/forms";
import {
  CANCELLED_REFUND_MATCH,
  CANCELLED_SWEEP_DEBITED,
  CANCELLED_SWEEPS_MATCH,
  CANCELLED_SWEEP_MATCH,
  DEBIT_REVIEW,
  PAYOUT_AMOUNT_MATCH_RETURN,
  REFUND_AMOUNT_MATCH_BARRED,
  checkLabel,
  debitErrorCode,
  debitReviewText,
  refundInDownloadedFileNote,
} from "@/lib/payments/debits";
import { TRANSFER_LINE_ACTION, transferLineErrorText } from "@/lib/payments/transfer-lines";
import { refusalText as creditNoteRefusalText } from "@/lib/remittance/credit-notes";
import {
  evidenceStatus,
  holdLabel,
  refusalText,
  runPayoutInDownloadedFileNote,
  sweepHoldLabel,
  transferErrorCode,
} from "@/lib/remittance/transfers";

/**
 * M2c-6b-3a (docs/design/m2c-6b-3-plan.md §4): the texts the pages show are true both ways — the switch off (as it
 * ships: its texts unchanged) and on (6b-3b's one-line migration): the pages read the flag
 * (public.cancellation_after_download) and pass it; each « on » text says how the cancellation after download is
 * asked, never that it is « not available yet ».
 */
const NOT_YET =
  /pas encore disponible|ne peut pas être annulé d'ici là|pas encore être annulé|ne peut pas encore être comptabilisé|jusqu'à ce que l'annulation après téléchargement soit disponible/;
const ON = { cancellationAfterDownload: true };

const SWITCHED: ErrorCode[] = [
  "run_already_sent",
  "run_payout_in_downloaded_file",
  "refund_in_downloaded_file",
  "credit_note_in_flight",
  "credit_note_run_in_flight",
  "transfer_cancellation_request_required",
  "transfer_file_holds_debited",
];

describe("M2c-6b-3a: the refusals worded both ways", () => {
  it("keeps every « off » text: the flag off (or not given) reads the text of the switch off", () => {
    for (const code of SWITCHED) {
      expect(errorText(code, { cancellationAfterDownload: false }), code).toBe(errorText(code));
      expect(errorText(code, ON), code).not.toBe(errorText(code));
    }
    // the switch off still says it is not available yet where it said so
    expect(errorText("run_payout_in_downloaded_file")).toContain("pas encore disponible");
    expect(errorText("transfer_cancellation_request_required")).toContain("Gardez-le tel quel");
  });

  it("never says, once the switch is on, that the cancellation after download is not available", () => {
    for (const code of SWITCHED) expect(errorText(code, ON), code).not.toMatch(NOT_YET);
  });

  it("sends ops to the file's cancellation, on evidence and by two people (T4, T5, T7)", () => {
    for (const code of ["run_already_sent", "run_payout_in_downloaded_file", "refund_in_downloaded_file"] as ErrorCode[]) {
      const t = errorText(code, ON);
      expect(t, code).toContain("faites d'abord annuler ce virement depuis la page du fichier");
      expect(t, code).toContain("relevés à l'appui, confirmée par une autre personne");
      expect(t, code).toContain("comptabilisé depuis le relevé bancaire");
    }
    expect(errorText("transfer_cancellation_request_required", ON)).toBe(
      "Ce fichier a été téléchargé : il ne se remplace plus d'un clic. Demandez son annulation, relevés à l'appui ; une autre personne la confirme.",
    );
  });

  it("words the credit-note refusals both ways (T6): a run in a downloaded file is cancelled once its transfer is", () => {
    for (const code of ["credit_note_in_flight", "credit_note_run_in_flight"] as ErrorCode[]) {
      expect(errorText(code, ON), code).toContain(
        "ensuite il ne peut l'être qu'une fois son virement annulé, relevés à l'appui (deux personnes). Sinon l'avoir est possible dès que son débit est comptabilisé depuis le relevé",
      );
      // review round 1 (LD-4, pages-texts-8): once its debit is booked the run is « Comptabilisé », never cancellable
      expect(errorText(code, ON), code).not.toContain("ou son débit comptabilisé");
      expect(errorText(code), code).toContain("ne peut plus l'être et attend que son débit soit comptabilisé");
    }
    for (const r of ["in_flight", "run_in_flight"]) {
      expect(creditNoteRefusalText(r, true), r).toContain("une fois son virement annulé, relevés à l'appui");
      expect(creditNoteRefusalText(r, true), r).toContain("Sinon l'avoir est possible dès que son débit est comptabilisé");
      expect(creditNoteRefusalText(r, true), r).not.toContain("ou son débit comptabilisé");
      expect(creditNoteRefusalText(r, false), r).toBe(creditNoteRefusalText(r));
      expect(creditNoteRefusalText(r, true), r).not.toMatch(NOT_YET);
    }
    expect(creditNoteRefusalText("nothing_left", true)).toBe(creditNoteRefusalText("nothing_left"));
  });

  it("words a file's « holds a debited transfer » both ways (T19): true of a sweep and of the client's or payment's holds", () => {
    const on = errorText("transfer_file_holds_debited", ON);
    expect(on).toContain("sans référence");
    expect(on).toContain("un virement annulé du même client ou du même paiement a été débité en retard");
    expect(on).toContain("la quote-part du cabinet de ce fichier a déjà été virée par une quote-part annulée exécutée en retard");
    expect(errorText("transfer_file_holds_debited")).not.toContain("quote-part");
    const dl = refusalText("holds_debited_transfer", [], true);
    expect(dl).toContain("sans référence");
    expect(dl).toContain("quote-part annulée exécutée en retard");
    expect(refusalText("holds_debited_transfer", [], false)).toBe(refusalText("holds_debited_transfer"));
  });
});

describe("M2c-6b-3a: the « not executed » sentences and the notes (T1–T3, T9, T11)", () => {
  it("says the cancellation « may » be asked once its days' statements are imported (critic 2-13)", () => {
    for (const [off, on] of [
      [PAYOUT_NOT_EXECUTED, PAYOUT_NOT_EXECUTED_ON],
      [FILE_TRANSFER_NOT_EXECUTED, FILE_TRANSFER_NOT_EXECUTED_ON],
      [REFUND_NOT_EXECUTED, REFUND_NOT_EXECUTED_ON],
    ]) {
      expect(off).toContain("jusqu'à ce que l'annulation après téléchargement soit disponible");
      expect(on).not.toMatch(NOT_YET);
      expect(on).toContain("une fois importés les relevés de son jour d'exécution et du jour ouvré suivant");
      expect(on).toContain("peut être demandée, relevés à l'appui, puis confirmée par une autre personne");
    }
    expect(REFUND_NOT_EXECUTED_ON).toContain("le remboursement est ensuite annulé ou réémis");
  });

  it("words the run page's and the payment page's notes both ways, the « off » note unchanged", () => {
    expect(runPayoutInDownloadedFileNote("TF-2026-000142", false)).toBe(runPayoutInDownloadedFileNote("TF-2026-000142"));
    expect(runPayoutInDownloadedFileNote("TF-2026-000142")).toContain("pas encore disponible");
    const run = runPayoutInDownloadedFileNote("TF-2026-000142", true);
    expect(run).toContain("TF-2026-000142");
    expect(run).toContain("faites d'abord annuler ce virement depuis la page du fichier");
    expect(run).toContain("si la banque du bénéficiaire le renvoie, son retour");
    expect(run).not.toMatch(NOT_YET);
    expect(refundInDownloadedFileNote("TF-2026-000143", false)).toBe(refundInDownloadedFileNote("TF-2026-000143"));
    const refund = refundInDownloadedFileNote("TF-2026-000143", true);
    expect(refund).toContain("TF-2026-000143");
    expect(refund).toContain("faites d'abord annuler ce virement depuis la page du fichier");
    expect(refund).not.toMatch(NOT_YET);
  });
});

describe("M2c-6b-3a: « Contrôles » both ways (T12, T15)", () => {
  it("keeps the « off » help, and says the « on » help by the row's case", () => {
    for (const code of ["file_not_marked_sent", "transfer_already_debited"]) {
      expect(checkLabel(code, { cancellationAfterDownload: false }), code).toEqual(checkLabel(code));
      expect(checkLabel(code, { cancellationAfterDownload: true }).label, code).toBe(checkLabel(code).label);
    }
    expect(checkLabel("file_not_marked_sent").help).toContain("ne peut pas encore être annulé");
    const sent = checkLabel("file_not_marked_sent", { cancellationAfterDownload: true }).help;
    expect(sent).toContain("demandez son annulation depuis sa page, relevés à l'appui (deux personnes)");
    expect(sent).toContain("son annulation peut être demandée une fois importés les relevés");
    expect(sent).not.toMatch(NOT_YET);
    const help = (details: Record<string, unknown>) =>
      checkLabel("transfer_already_debited", { cancellationAfterDownload: true, details }).help;
    expect(help({ kind: "sweep", status: "cancelled" })).toContain(
      `tant que son débit n'est ni comptabilisé ni revenu. Comptabilisez-le dans « Débits et retours » (« Comptabiliser… », puis « ${TRANSFER_LINE_ACTION.unplanned_sweep.label} » de cette quote-part)`,
    );
    expect(help({ kind: "sweep", status: "in_file", reason: "cancelled_sweep_debited" })).toContain(
      "faites-le annuler depuis sa page, relevés à l'appui (deux personnes) : la quote-part sera recalculée",
    );
    expect(help({ kind: "payout", status: "ordered", reason: "client_payout_debited_late" })).toContain(
      "après avoir annulé ce reversement s'il reprend les mêmes encaissements",
    );
    expect(help({ kind: "refund", status: "ordered", reason: "payment_refund_debited_late" })).toContain(
      "Rattachez d'abord ce débit",
    );
    expect(help({ kind: "refund", status: "cancelled" })).toContain("Ne refaites pas ce remboursement");
    expect(help({ kind: "payout", status: "cancelled" })).toContain("« Virement hors reversement »");
    // review round 1 (pages-texts-3, -6): a debit without our references only may be the earlier one's; dated after
    // this one's execution, it may be its own — booked as its debit then — and the file's cancellation is refused
    const reissue = help({ kind: "payout", status: "ordered" });
    expect(reissue).toContain("ou un débit sans nos références qui peut l'être, du virement qu'il remplace");
    expect(reissue).toContain("« Comptabiliser… » le propose alors comme son débit");
    expect(reissue).toContain("l'annulation de ce fichier est refusée tant que ce débit n'est ni comptabilisé ni classé");
    expect(reissue).toContain("demandez à la banque le détail de ce débit et prévenez le support");
    // the round-5 help of the switch off said a cancelled sweep's debit holds the share « until it came back »: not
    // once ops book it (B)
    expect(help({ kind: "sweep", status: "cancelled" })).not.toContain("tant qu'une quote-part annulée débitée n'est pas revenue");
  });
});

describe("M2c-6b-3a: the new codes have words", () => {
  it("the holds (M, A), the sweep's hold both ways (B), the evidence's refusal (N), rule 3b's (iv) (K)", () => {
    for (const code of ["client_payout_debited_late", "payment_refund_debited_late", "cancelled_sweep_debited"])
      expect(holdLabel(code), code).not.toBe(code);
    // review round 1 (LD-3, pages-texts-3): only « peut-être » — the line may carry none of our references
    expect(holdLabel("client_payout_debited_late")).toContain("un virement annulé de ce client a peut-être été débité en retard");
    expect(sweepHoldLabel("cancelled_sweep_debited", false)).toBe(sweepHoldLabel("cancelled_sweep_debited"));
    // review round 1 (pages-texts-1): the button the sheet shows (the unplanned sweep's label)
    expect(sweepHoldLabel("cancelled_sweep_debited", true)).toContain(
      `« Comptabiliser… », puis « ${TRANSFER_LINE_ACTION.unplanned_sweep.label} » de cette quote-part`,
    );
    expect(sweepHoldLabel("cancelled_sweep_debited", true)).toContain("demandez à la banque le détail de ce débit");
    expect(sweepHoldLabel("cancelled_sweep_debited", true)).not.toContain("prévenez le support");
    expect(transferErrorCode("transfer file refused: unreferenced_debit_open")).toBe("transfer_unreferenced_debit_open");
    expect(transferErrorCode("transfer refused: unreferenced_debit_open")).toBe("transfer_unreferenced_debit_open");
    expect(errorText("transfer_unreferenced_debit_open")).toContain("débit sans nos références");
    expect(transferLineErrorText("cancelled_transfer_matches")).toContain(
      "l'exécution tardive d'un remboursement ou d'une quote-part annulés après téléchargement",
    );
  });

  it("the evidence card says from when a debit without our references blocks the cancellation (N)", () => {
    const base = {
      statement_to_date: "2026-11-10",
      needed_to_date: "2026-11-09",
      covered: true,
      debit_seen: false,
      returned: false,
      window_over: true,
      available_from: "2026-11-10",
      batch_ambiguous: false,
      file_executed: null,
      refusal: "unreferenced_debit_open",
    };
    const s = evidenceStatus({ ...base, unreferenced_debit: true, unreferenced_from: "2026-11-06" }, "file");
    expect(s.ready).toBe(false);
    expect(s.text).toContain("Depuis le 06/11/2026, le relevé montre un débit sans nos références");
    // review round 1 (pages-texts-5): the exit when « Débits et retours » cannot book it; one transfer's own words
    expect(s.text).toContain("si cette page ne permet pas de le comptabiliser (plusieurs virements possibles), demandez à la banque");
    const one = evidenceStatus({ ...base, unreferenced_debit: true, unreferenced_from: "2026-11-06" }, "transfer").text;
    expect(one).toContain("du montant de ce virement, pas encore comptabilisé");
    expect(one).not.toContain("d'un virement de ce montant");
    expect(errorText("transfer_unreferenced_debit_open")).toContain("demandez à la banque le détail de ce débit");
    expect(evidenceStatus(base, "transfer").ready).toBe(false);
    // the card of a file without such a line is unchanged
    expect(
      evidenceStatus({ ...base, refusal: null, unreferenced_debit: false, unreferenced_from: null }, "file").ready,
    ).toBe(true);
  });
});

describe("M2c-6b-3a: « À classer » on a debit whose only candidate is a cancelled refund or sweep (K)", () => {
  it("says the sweep's late debit is booked as that sweep's, a refund's not yet; a payout's text unchanged", () => {
    const row = (kind: string) => ({
      id: "l1",
      direction: "debit",
      kind: "other_debit",
      end_to_end_id: null,
      payment_info_id: null,
      review_reason: "payout_amount_match",
      candidates: [{ transfer_id: "t1", kind, status: "cancelled", run_status: null }],
    });
    expect(debitReviewText(row("sweep") as never)).toBe(CANCELLED_SWEEP_MATCH);
    expect(debitReviewText(row("refund") as never)).toBe(CANCELLED_REFUND_MATCH);
    // review round 1 (pages-texts-1): the label « Comptabiliser… » shows for that proposal
    expect(CANCELLED_SWEEP_MATCH).toContain(`« ${TRANSFER_LINE_ACTION.unplanned_sweep.label} » de cette quote-part`);
    expect(CANCELLED_REFUND_MATCH).toContain("Il ne peut pas encore être comptabilisé");
    expect(debitReviewText(row("payout") as never)).not.toBe(CANCELLED_REFUND_MATCH);
  });
});

describe("M2c-6b-3a review round 1: the texts a debit without our references makes true (LD-3, pages-texts-1…9, tests-1, tests-6)", () => {
  const LABELS = Object.values(TRANSFER_LINE_ACTION).map((a) => a.label);

  it("never names a button the sheets do not show (« Quote-part hors ordre »)", () => {
    expect(LABELS).not.toContain("Quote-part hors ordre");
    for (const t of [
      CANCELLED_SWEEP_MATCH,
      CANCELLED_SWEEP_DEBITED,
      sweepHoldLabel("cancelled_sweep_debited", true) ?? "",
      holdLabel("cancelled_sweep_debited") ?? "",
      checkLabel("transfer_already_debited", { cancellationAfterDownload: true, details: { kind: "sweep", status: "cancelled" } }).help,
    ]) {
      expect(t).not.toContain("Quote-part hors ordre");
      expect(t).toContain(`« ${TRANSFER_LINE_ACTION.unplanned_sweep.label} »`);
    }
  });

  it("words the run's and the refund's « already debited » refusal both ways, the « off » text unchanged", () => {
    for (const code of ["run_transfer_already_debited", "refund_already_debited"] as ErrorCode[]) {
      expect(errorText(code, { cancellationAfterDownload: false }), code).toBe(errorText(code));
      expect(errorText(code), code).toContain("Prévenez le support pour rattacher ce débit");
      const on = errorText(code, ON);
      expect(on, code).toContain("ou un débit sans nos références de son montant, pas encore comptabilisé ni classé, peut être l'exécution tardive du virement qu'il remplace");
      expect(on, code).toContain("Voyez ce débit dans « Débits et retours »");
      expect(on, code).not.toContain("Prévenez le support pour rattacher");
    }
  });

  it("words the « already debited » hold both ways (« Virements », the file page), the « off » label unchanged", () => {
    expect(holdLabel("already_debited", false)).toBe(holdLabel("already_debited"));
    expect(holdLabel("already_debited")).toContain("le débit sera rattaché (prévenez le support)");
    const on = holdLabel("already_debited", true) ?? "";
    expect(on).toContain("ou un débit sans nos références de son montant");
    expect(on).toContain("Voyez ce débit dans « Débits et retours »");
    expect(on).not.toContain("le débit sera rattaché");
    // a hold of the switch off keeps its words with the flag on
    expect(holdLabel("payout_not_covered", true)).toBe(holdLabel("payout_not_covered"));
  });

  it("says a cancelled sweep's hold is recalculated whichever arm raised it (pages-texts-7)", () => {
    const t = holdLabel("cancelled_sweep_debited") ?? "";
    expect(t).toContain("la quote-part est recalculée au prochain fichier d'après ce que le cabinet a déjà reçu");
    expect(t).toContain("Si le débit de la quote-part annulée n'est pas encore comptabilisé, comptabilisez-le d'abord");
  });

  it("words a cancelled sweep's own late debit as that sweep's (pages-texts-2), several cancelled sweeps as ambiguous", () => {
    const line = {
      id: "l1",
      direction: "debit",
      kind: "transfer_out",
      end_to_end_id: "SWP518178332569",
      payment_info_id: null,
      review_reason: "cancelled_transfer_debited",
      candidates: [{ transfer_id: "s1", run_status: null }],
    };
    expect(debitReviewText(line as never)).toBe(CANCELLED_SWEEP_DEBITED);
    expect(debitReviewText({ ...line, end_to_end_id: "RMT518178332569" } as never)).toBe(DEBIT_REVIEW.cancelled_transfer_debited);
    const two = {
      id: "l2",
      direction: "debit",
      kind: "other_debit",
      end_to_end_id: null,
      payment_info_id: null,
      review_reason: "payout_amount_match",
      candidates: [
        { transfer_id: "s1", kind: "sweep", status: "cancelled", run_status: null },
        { transfer_id: "s2", kind: "sweep", status: "cancelled", run_status: null },
      ],
    };
    expect(debitReviewText(two as never)).toBe(CANCELLED_SWEEPS_MATCH);
    expect(CANCELLED_SWEEPS_MATCH).not.toContain("remboursement");
  });

  it("names the payment's return « À classer » still offers beside a cancelled refund (pages-texts-9)", () => {
    const row = {
      id: "l3",
      bank_transaction_id: "l3",
      direction: "debit",
      kind: "other_debit",
      end_to_end_id: null,
      payment_info_id: null,
      amount_minor: "5000",
      review_reason: "payout_amount_match",
      candidates: [{ transfer_id: "q0", kind: "refund", status: "cancelled", run_status: null }],
    };
    const payments = [
      { payment_id: "p71", amount_minor: "5000", left_minor: "5000", booking_date: "2026-11-17", payer_name: "X", status: "unmatched" },
    ];
    expect(debitReviewText(row as never, { return_guard: null, payments: payments as never })).toBe(
      `${CANCELLED_REFUND_MATCH} ${PAYOUT_AMOUNT_MATCH_RETURN}`,
    );
    expect(debitReviewText(row as never, { return_guard: null, payments: [] })).toBe(CANCELLED_REFUND_MATCH);
  });

  it("says why a refund of the line's amount is not offered (pages-texts-4), else the job's text", () => {
    const row = {
      id: "l4",
      direction: "debit",
      kind: "other_debit",
      end_to_end_id: null,
      payment_info_id: null,
      review_reason: "refund_amount_match",
      candidates: [{ refund_request_id: "r2", payment_id: "p71" }],
    };
    expect(debitReviewText(row as never, { refunds: [] })).toBe(REFUND_AMOUNT_MATCH_BARRED);
    expect(debitReviewText(row as never, { refunds: [{ refund_request_id: "r2" }] })).toBe(DEBIT_REVIEW.refund_amount_match);
    expect(debitReviewText(row as never)).toBe(DEBIT_REVIEW.refund_amount_match);
  });

  it("words the refund link's refusals of a cancelled transfer (DP-1, DP-2, pages-texts-4)", () => {
    expect(
      debitErrorCode("debit link refused: posting_failed (23514: refund refused: cancelled_transfer_matches)"),
    ).toBe("refund_cancelled_transfer_matches");
    const barred = errorText("refund_cancelled_transfer_matches");
    expect(barred).toContain("annulé après téléchargement");
    expect(barred).toContain("Demandez à la banque le détail de ce débit");
    expect(errorText("refund_reissue_in_downloaded_file", { cancellationAfterDownload: false })).toBe(
      errorText("refund_reissue_in_downloaded_file"),
    );
    expect(errorText("refund_reissue_in_downloaded_file")).toContain("gardez le fichier tel quel");
    const on = errorText("refund_reissue_in_downloaded_file", ON);
    expect(on).toContain("qu'un virement de ce montant annulé après téléchargement (remboursement, reversement ou quote-part du cabinet) peut en être l'exécution tardive");
    expect(on).not.toContain("gardez le fichier tel quel");
  });

  // tests-1, tests-6: the pages pass the flag to the forms and labels that receive a switched code (a source guard: the
  // project has no component renderer)
  it("passes the flag to the file page's « Annuler le fichier », the holds, and the debits page's refund link", () => {
    const src = (p: string) => readFileSync(join(__dirname, "../../app/backoffice", p), "utf8");
    const actions = src("reversements/virements/file-actions.tsx");
    const cancelFile = actions.slice(actions.indexOf("export function CancelFile"), actions.indexOf("type Target ="));
    expect(cancelFile).toMatch(/<ActionForm[^>]*cancellationAfterDownload=\{cancellationAfterDownload\}/);
    const filePage = src("reversements/virements/[id]/page.tsx");
    expect(filePage).toMatch(/<CancelFile[^>]*cancellationAfterDownload=\{cancellable\}/);
    expect(filePage).not.toMatch(/holdLabel\([^,)]*\)/);
    const list = src("reversements/virements/page.tsx");
    expect(list).toContain("holdLabel(t.hold, cancellationAfterDownload)");
    expect(list).toMatch(/<TransferRow[^>]*cancellationAfterDownload=/);
    const debits = src("encaissements/debits/page.tsx");
    expect(debits).toContain('supabase.rpc("cancellation_after_download")');
    expect(debits).toMatch(/<LinkRefund[^>]*cancellationAfterDownload=\{cancellationAfterDownload\}/);
    const debitActions = src("encaissements/debits/debit-actions.tsx");
    const linkRefund = debitActions.slice(debitActions.indexOf("export function LinkRefund"), debitActions.indexOf("export function BookLine"));
    expect(linkRefund).toMatch(/<ActionForm[^>]*cancellationAfterDownload=\{cancellationAfterDownload\}/);
  });
});
