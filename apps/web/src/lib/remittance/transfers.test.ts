import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { runErrorCode } from "@/lib/remittance/runs";
import {
  type PayingAccount,
  cashLines,
  downloadWarning,
  fileLive,
  fileStatus,
  generationEffects,
  holdLabel,
  parisDateTime,
  parisDayMonth,
  parisTime,
  transferErrorCode,
} from "@/lib/remittance/transfers";

const n = (s: string) => s.replace(/ | /g, " ");

const account: PayingAccount = {
  bank_account_id: "80000000-0000-0000-0000-0000000000cf",
  label: "Fonds de tiers",
  iban_last4: "1001",
  bic: "TESTFRPPXXX",
  currency: "EUR",
  pain_version: "pain.001.001.09",
  earliest_execution_date: "2026-11-03",
  cash: null,
  sweep_preview_minor: "96864",
  to_file_count: 3,
  eligible_count: 2,
  eligible_total_minor: "615136",
  late_count: 1,
  to_file: [],
  files: [],
};

describe("« Virements » words (design §11, §17.3)", () => {
  it("names every file status, a downloaded file is not yet « transmis »", () => {
    expect(fileStatus("downloaded").label).toBe("Téléchargé — à déposer à la banque");
    expect(fileStatus("sent").label).toBe("Transmis à la banque");
    expect(fileStatus("rejected").tone).toBe("error");
    expect(fileStatus("whatever").label).toBe("whatever");
    expect(fileLive("generated") && fileLive("sent") && !fileLive("superseded") && !fileLive("failed")).toBe(true);
  });

  it("says why a transfer is held out of a file, in French, never the code", () => {
    expect(holdLabel(null)).toBeNull();
    expect(holdLabel("payout_not_covered")).toContain("Montant supérieur à ce qui reste dû au client");
    expect(holdLabel("late_reason_required")).toContain("motif du retard");
    expect(holdLabel("payout_blocked:payee_name_mismatch")).toBe(
      "Virement bloqué — la banque a signalé un nom de bénéficiaire non concordant : à vérifier avec le client",
    );
    expect(holdLabel("payout_blocked:payout_account_returned")).toContain("IBAN à remplacer ou reconfirmer");
  });

  it("warns on a second download with who and when, in Paris time (ops critique #33)", () => {
    expect(downloadWarning({ download_count: 0, first_downloaded_at: null, first_downloaded_by: null })).toBeNull();
    // 02/11/2026 08:41 UTC = 09:41 in Paris (winter time)
    expect(
      downloadWarning({ download_count: 1, first_downloaded_at: "2026-11-02T08:41:00Z", first_downloaded_by: "Léa" }),
    ).toBe("Déjà téléchargé par Léa le 02/11 à 09:41 — ne le déposez pas deux fois");
    expect(parisDayMonth("2026-07-01T22:30:00Z")).toBe("02/07"); // summer time: already the next day in Paris
    expect(parisTime("2026-07-01T22:30:00Z")).toBe("00:30");
    expect(parisDateTime("2026-11-02T08:41:00Z")).toBe("02/11/2026 à 09:41");
  });

  it("states the cash check from the last closing balance, amounts from minor units", () => {
    expect(cashLines(null, "EUR")[0]).toContain("Aucun relevé avec solde de clôture importé");
    const lines = cashLines(
      {
        statement_id: "x",
        closing_date: "2026-11-02",
        closing_minor: "719500",
        debits_since_minor: "0",
        in_flight_minor: "96864",
        in_flight_count: 1,
        manual_refunds_minor: "8000",
        available_minor: "614636",
      },
      "EUR",
    ).map(n);
    expect(lines).toEqual([
      "Solde au 02/11/2026 : 7 195,00 €",
      "1 virement déjà en route (fichiers téléchargés, débit non encore vu) : − 968,64 €",
      "remboursements à exécuter dans la banque : − 80,00 €",
      "disponible pour un fichier : 6 146,36 €",
    ]);
  });

  it("states every effect of « Générer le fichier » before the command", () => {
    const effects = generationEffects(account, { id: "o", label: "Compte propre", iban_last4: "0129" }).map(n);
    expect(effects[0]).toBe(
      "2 virements depuis Fonds de tiers (…1001) : 6 151,36 €, exécution demandée au plus tôt le 03/11/2026.",
    );
    expect(effects[1]).toContain("968,64 €, part dans le même fichier vers le compte propre (…0129)");
    expect(effects[1]).toContain("après les clients");
    expect(effects).toContain("1 virement reste hors du fichier (motif affiché).");
    expect(effects.some((e) => e.includes("motif du retard est enregistré sur le fichier"))).toBe(true);
    expect(effects.at(-1)).toContain("Rien n'est comptabilisé avant le débit sur le relevé");
    expect(effects.join(" ")).not.toMatch(/payé|débité le/);
    const noOwn = generationEffects(account, null);
    expect(noOwn[1]).toContain("aucun compte propre n'est renseigné");
  });

  it("maps every command refusal to a French message (never the database's text)", () => {
    const cases: [string, string][] = [
      ["transfer file refused: nothing_to_file", "transfer_nothing_to_file"],
      ["transfer file refused: cash_not_covered", "transfer_cash_not_covered"],
      ["transfer file refused: no_closing_balance", "transfer_no_closing_balance"],
      ["transfer file refused: already_downloaded", "transfer_already_downloaded"],
      ["transfer file refused: hash_mismatch", "transfer_hash_mismatch"],
      ["transfer file refused: attestation_required", "transfer_attestation_required"],
      ["transfer file refused: debit_seen", "transfer_debit_seen"],
      ["transfer file refused: version_changed", "transfer_version_changed"],
      ["transfer file refused: already_sent", "transfer_already_sent"],
      ["payee check refused: four_eyes", "payee_check_four_eyes"],
      ["not allowed", "not_allowed"],
      ["something else", "unknown"],
    ];
    for (const [message, code] of cases) {
      expect(transferErrorCode(message)).toBe(code);
      expect(errorText(transferErrorCode(message))).not.toMatch(/refused|transfer file/);
    }
    // the run's cancellation after download (§9.7)
    expect(runErrorCode("remittance run refused: attestation_required")).toBe("transfer_attestation_required");
    expect(runErrorCode("remittance run refused: statement_not_imported")).toBe("transfer_statement_not_imported");
    expect(runErrorCode("remittance run refused: debit_seen")).toBe("transfer_debit_seen");
    expect(errorText("transfer_statement_not_imported")).toContain("relevé du jour d'exécution");
  });
});
