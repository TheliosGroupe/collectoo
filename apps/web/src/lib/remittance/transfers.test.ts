import { describe, expect, it } from "vitest";
import { errorText } from "@/lib/boarding/forms";
import { runErrorCode } from "@/lib/remittance/runs";
import {
  type FileCard,
  type PayingAccount,
  canGenerate,
  cancellationCall,
  cancellationOf,
  cancellationRpc,
  cancellationStep,
  cashLines,
  downloadOutcome,
  downloadWarning,
  evidenceStatus,
  fileLive,
  fileStale,
  fileStatus,
  generateLabel,
  generationEffects,
  holdLabel,
  parisDate,
  parisDateTime,
  parisDayMonth,
  parisTime,
  payeeCheckClearable,
  payeeCheckErrorCode,
  refusalFromSearch,
  refusalText,
  refusalUrl,
  regenerationEffects,
  requestLine,
  runCancelPath,
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

const file = (over: Partial<FileCard> = {}): FileCard => ({
  id: "f0000000-0000-0000-0000-000000000001",
  number: "TF-2026-000087",
  status: "generated",
  version: 3,
  pain_version: "pain.001.001.09",
  nb_of_txs: 2,
  ctrl_sum_minor: "583840",
  currency: "EUR",
  first_execution_date: "2026-11-12",
  last_execution_date: "2026-11-12",
  created_at: "2026-11-11T08:00:00Z",
  generated_at: "2026-11-11T08:00:05Z",
  xsd_validated: false,
  file_sha256: "ab",
  size_bytes: 1000,
  download_count: 0,
  first_downloaded_at: null,
  first_downloaded_by: null,
  sent_marked_at: null,
  sent_marked_by: null,
  closed_at: null,
  close_reason: null,
  close_attestation: null,
  error: null,
  late_reason: null,
  held_count: 0,
  ...over,
});

const T1 = "a0000000-0000-4000-8000-000000000001";
const T2 = "a0000000-0000-4000-8000-000000000002";
const KEY = "b0000000-0000-4000-8000-000000000001";
const FILE = "f0000000-0000-4000-8000-000000000001";

describe("M2c-6a review T2: a file no longer downloadable is regenerated, never served (pain001#0, money#0, security#0)", () => {
  it("flags a generated file whose execution date is before the account's next execution day, or that the database flags", () => {
    expect(fileStale(file(), "2026-11-12")).toBe(false);
    // the cut-off passed (or the day did): the account's next execution day is after the file's date
    expect(fileStale(file(), "2026-11-13")).toBe(true);
    expect(fileStale(file({ stale: "file_blocked" }), "2026-11-12")).toBe(true);
    expect(fileStale(file({ stale: true }), null)).toBe(true);
    // only a generated file: a downloaded one is not regenerated (T1 cancels it), a superseded one is already replaced
    expect(fileStale(file({ status: "downloaded", download_count: 1 }), "2026-11-13")).toBe(false);
    expect(fileStale(file({ status: "superseded" }), "2026-11-13")).toBe(false);
  });

  it("offers « Régénérer le fichier » when the file it replaces is stale, even with nothing else to file", () => {
    const stale: PayingAccount = { ...account, eligible_count: 0, eligible_total_minor: "0", to_file_count: 0, late_count: 0, sweep_preview_minor: "0", earliest_execution_date: "2026-11-13", files: [file()] };
    expect(canGenerate(stale)).toBe(true);
    expect(generateLabel(stale)).toBe("Régénérer le fichier");
    const effects = generationEffects(stale, null).map(n);
    expect(effects[0]).toBe(
      "Le fichier TF-2026-000087 (2 virements, 5 838,40 €) n'a pas été téléchargé et sa date d'exécution est passée : il est remplacé, et ses virements sont repris s'ils passent les contrôles d'aujourd'hui (exécution au plus tôt le 13/11/2026).",
    );
    expect(effects.join(" ")).not.toContain("Aucun reversement ni remboursement");
    expect(effects.at(-1)).toContain("Rien n'est comptabilisé avant le débit sur le relevé");
    // nothing to file and nothing to replace: no button; a fresh file to replace: « Générer »
    expect(canGenerate({ ...stale, files: [file({ status: "sent" })] })).toBe(false);
    expect(generateLabel({ ...stale, earliest_execution_date: "2026-11-12" })).toBe("Générer le fichier");
    expect(canGenerate({ ...stale, currency: "USD" })).toBe(false);
  });

  it("says what « Régénérer » does from the file's own page", () => {
    const e = regenerationEffects({ number: "TF-2026-000087", bank_account: { id: "b", label: "Fonds de tiers", iban_last4: "1001" } });
    expect(e[0]).toContain("Fonds de tiers (…1001), avec un nouveau numéro");
    expect(e[1]).toContain("ceux du fichier TF-2026-000087 qui passent les contrôles d'aujourd'hui");
    expect(e.join(" ")).toContain("motif du retard");
  });

  it("reads the download command's answer: served, or refused with what replaced the file", () => {
    expect(downloadOutcome({ file_id: FILE, download: 1, storage_path: "org/f.xml" }, null)).toEqual({
      kind: "ok",
      storagePath: "org/f.xml",
      signedUrl: null,
    });
    expect(downloadOutcome({ storage_path: "p", signed_url: "http://127.0.0.1:54321/storage/v1/object/sign/x" }, null)).toMatchObject({
      kind: "ok",
      signedUrl: "http://127.0.0.1:54321/storage/v1/object/sign/x",
    });
    // a refusal that replaced the file comes back as data (a raise would undo the replacement)
    expect(downloadOutcome({ refused: "file_stale", status: "superseded" }, null)).toEqual({ kind: "refused", code: "file_stale", blocked: [] });
    expect(
      downloadOutcome(
        {
          refused: "file_blocked",
          blocked: [
            { transfer_id: T1, reason: "payout_account_changed" },
            { transfer_id: T2, reason: "payout_blocked:payee_name_mismatch" },
            { transfer_id: "not-a-uuid", reason: "x" },
            { transfer_id: T2, reason: "<script>" },
          ],
        },
        null,
      ),
    ).toEqual({
      kind: "refused",
      code: "file_blocked",
      blocked: [
        { transfer_id: T1, reason: "payout_account_changed" },
        { transfer_id: T2, reason: "payout_blocked:payee_name_mismatch" },
      ],
    });
    // the file's own reason (the cash check) has no transfer id; the database's extra fields are ignored
    expect(
      downloadOutcome(
        {
          refused: "file_blocked",
          blocked: [
            { transfer_id: T1, kind: "payout", amount_minor: "164000", reason: "payout_not_covered" },
            { transfer_id: null, reason: "cash_not_covered", available_minor: "100", needed_minor: "583840" },
            { transfer_id: 7, reason: "x" },
          ],
        },
        null,
      ),
    ).toEqual({
      kind: "refused",
      code: "file_blocked",
      blocked: [
        { transfer_id: T1, reason: "payout_not_covered" },
        { transfer_id: null, reason: "cash_not_covered" },
      ],
    });
    // one that changed nothing is an error (its detail may name the transfers too)
    expect(downloadOutcome(null, { message: "transfer file refused: already_downloaded" })).toEqual({
      kind: "refused",
      code: "already_downloaded",
      blocked: [],
    });
    expect(
      downloadOutcome(null, {
        message: "transfer file refused: file_blocked",
        details: JSON.stringify({ blocked: [{ transfer_id: T1, reason: "payout_not_covered" }] }),
      }),
    ).toEqual({ kind: "refused", code: "file_blocked", blocked: [{ transfer_id: T1, reason: "payout_not_covered" }] });
    expect(downloadOutcome(null, { message: "transfer file refused: not_downloadable", details: "{bad json" })).toMatchObject({
      code: "not_downloadable",
    });
    expect(downloadOutcome(null, { message: "transfer file refused: not_ready" })).toMatchObject({ code: "not_ready" });
    expect(downloadOutcome(null, { message: "boom" })).toMatchObject({ kind: "refused", code: "unknown" });
  });

  it("sends a refusal back to the file's page (never a bare text page, tests-ui#9) and reads it there", () => {
    const url = refusalUrl(FILE, "file_blocked", [
      { transfer_id: T1, reason: "payout_account_changed" },
      { transfer_id: T2, reason: "payout_blocked:payee_name_mismatch" },
    ]);
    expect(url).toBe(
      `/backoffice/reversements/virements/${FILE}?refus=file_blocked&b=${T1}%3Apayout_account_changed&b=${T2}%3Apayout_blocked%3Apayee_name_mismatch`,
    );
    const params = Object.fromEntries(
      [...new URLSearchParams(url.split("?")[1]).entries()].reduce((m, [k, v]) => m.set(k, [...(m.get(k) ?? []), v]), new Map<string, string[]>()),
    );
    expect(refusalFromSearch(params)).toEqual({
      code: "file_blocked",
      blocked: [
        { transfer_id: T1, reason: "payout_account_changed" },
        { transfer_id: T2, reason: "payout_blocked:payee_name_mismatch" },
      ],
    });
    expect(refusalFromSearch({ refus: "file_stale" })).toEqual({ code: "file_stale", blocked: [] });
    // the file's own reason travels with no transfer id
    const cash = refusalUrl(FILE, "file_blocked", [{ transfer_id: null, reason: "cash_not_covered" }]);
    expect(cash).toBe(`/backoffice/reversements/virements/${FILE}?refus=file_blocked&b=%3Acash_not_covered`);
    expect(refusalFromSearch({ refus: "file_blocked", b: ":cash_not_covered" })).toEqual({
      code: "file_blocked",
      blocked: [{ transfer_id: null, reason: "cash_not_covered" }],
    });
    expect(holdLabel("cash_not_covered")).toContain("ne couvre plus le fichier");
    expect(holdLabel("no_closing_balance")).toContain("Aucun relevé avec solde de clôture");
    // anything else in the query is ignored
    expect(refusalFromSearch({ refus: "drop table" })).toBeNull();
    expect(refusalFromSearch({})).toBeNull();
    expect(refusalFromSearch({ refus: "file_blocked", b: ["x:y", `${T1}:<b>`, `${T1}`] })).toEqual({ code: "file_blocked", blocked: [] });
    // at most 20 transfers travel in the URL
    const many = Array.from({ length: 30 }, () => ({ transfer_id: T1, reason: "payout_not_covered" }));
    expect(new URLSearchParams(refusalUrl(FILE, "file_blocked", many).split("?")[1]).getAll("b")).toHaveLength(20);
  });

  it("words every refusal of the download in French, with « Régénérez » for a replaced file", () => {
    expect(refusalText("file_stale")).toContain("Date d'exécution dépassée");
    expect(refusalText("file_stale")).toContain("Régénérez");
    expect(refusalText("file_blocked")).toContain("ne passent plus les contrôles");
    expect(refusalText("already_downloaded")).toContain("ne le déposez pas deux fois");
    for (const code of ["not_ready", "not_downloadable", "holds_cancelled_transfer", "hash_mismatch", "unavailable", "unknown"] as const)
      expect(refusalText(code)).not.toMatch(/refused|transfer file/);
    // and the commands' own refusals
    expect(transferErrorCode("transfer file refused: file_stale")).toBe("transfer_file_stale");
    expect(transferErrorCode("transfer file refused: file_blocked")).toBe("transfer_file_blocked");
    expect(errorText("transfer_file_stale")).toContain("Régénérez");
    expect(errorText("transfer_file_blocked")).toContain("Régénérez");
  });
});

describe("M2c-6a review T3: transfers a SEPA file cannot carry are held out with their reason (pain001#2, pain001#4)", () => {
  it("says why, and what to do, in French", () => {
    expect(holdLabel("payee_name_not_epc")).toContain("aucun caractère accepté par le format SEPA");
    expect(holdLabel("payee_name_not_epc")).toContain("hors du fichier");
    expect(holdLabel("iban_not_sepa")).toContain("hors de la zone SEPA");
    expect(holdLabel("iban_not_sepa")).toContain("à exécuter vous-même");
    // the names the findings used, should the database send them
    expect(holdLabel("iban_outside_sepa")).toBe(holdLabel("iban_not_sepa"));
    expect(holdLabel("payee_name_not_latin")).toBe(holdLabel("payee_name_not_epc"));
    expect(holdLabel("cash_not_covered")).toContain("ne couvre plus le fichier");
  });
});

describe("M2c-6a review T1: a downloaded file or one transfer is cancelled with the statement's evidence and four eyes", () => {
  const evidence = { statement_to_date: "2026-11-13", needed_to_date: "2026-11-13", covered: true, debit_seen: false, returned: false };
  const request = { requested_at: "2026-11-13T08:41:00Z", requested_by: "Léa", requested_by_me: false, reason: "non déposé", attestation: "not_uploaded" };

  it("reads the cancellation the database gives, anything malformed as « not known »", () => {
    expect(cancellationOf(undefined)).toEqual({ request: null, evidence: null });
    expect(cancellationOf({ request: null, evidence: null })).toEqual({ request: null, evidence: null });
    expect(cancellationOf({ request, evidence })).toEqual({ request, evidence });
    expect(cancellationOf({ request: { requested_by: "x" }, evidence: "yes" })).toEqual({ request: null, evidence: null });
    expect(cancellationOf({ evidence: { covered: "true", statement_to_date: "13/11/2026" } }).evidence).toEqual({
      statement_to_date: null,
      needed_to_date: null,
      covered: false,
      debit_seen: false,
      returned: false,
    });
  });

  it("asks, then lets only another person confirm", () => {
    expect(cancellationStep({ request: null, evidence })).toBe("request");
    expect(cancellationStep({ request, evidence })).toBe("confirm");
    expect(cancellationStep({ request: { ...request, requested_by_me: true }, evidence })).toBe("wait");
    expect(requestLine(request)).toBe(
      "Annulation demandée par Léa le 13/11/2026 à 09:41 : non déposé (Le fichier n'a pas été déposé à la banque)",
    );
  });

  it("states the evidence: the statement covering the date and the next business day, no debit, or the bank's rejection", () => {
    expect(evidenceStatus(evidence, "file")).toEqual({
      ready: true,
      text: "Relevés importés jusqu'au 13/11/2026 : aucun débit de ce fichier — la banque ne l'a pas exécuté.",
    });
    const missing = evidenceStatus({ ...evidence, statement_to_date: "2026-11-09", covered: false }, "file");
    expect(missing.ready).toBe(false);
    expect(missing.text).toBe(
      "Importez d'abord le relevé du compte jusqu'au 13/11/2026 (dernier relevé importé : jusqu'au 09/11/2026) : il doit montrer qu'aucun débit de ce fichier n'a eu lieu.",
    );
    expect(evidenceStatus({ ...evidence, statement_to_date: null, covered: false }, "transfer").text).toContain("dernier relevé importé : aucun");
    const seen = evidenceStatus({ ...evidence, debit_seen: true }, "transfer");
    expect(seen.ready).toBe(false);
    expect(seen.text).toContain("Un relevé montre un débit de ce virement");
    expect(seen.text).toContain("double paiement");
    expect(evidenceStatus({ ...evidence, debit_seen: true, returned: true }, "transfer")).toMatchObject({ ready: true });
    const unknown = evidenceStatus(null, "file");
    expect(unknown.ready).toBeNull();
    expect(unknown.text).toContain("jour ouvré qui suit la date d'exécution demandée");
  });

  it("calls the request and the confirmation with exactly their arguments, refusing what is incomplete before asking", () => {
    const fields = (m: Record<string, string>) => (k: string) => m[k] ?? "";
    expect(
      cancellationCall("request", "file", fields({ idempotency_key: KEY, file_id: FILE, expected_version: "4", reason: "non déposé", attestation: "not_uploaded" })),
    ).toEqual({
      fn: "request_transfer_file_cancellation",
      args: { p_idempotency_key: KEY, p_file_id: FILE, p_expected_version: 4, p_reason: "non déposé", p_attestation: "not_uploaded" },
    });
    expect(cancellationCall("confirm", "file", fields({ idempotency_key: KEY, file_id: FILE, expected_version: "5" }))).toEqual({
      fn: "confirm_transfer_file_cancellation",
      args: { p_idempotency_key: KEY, p_file_id: FILE, p_expected_version: 5 },
    });
    expect(cancellationCall("request", "transfer", fields({ idempotency_key: KEY, transfer_id: T1, reason: "refusé par la banque" }))).toEqual({
      fn: "request_transfer_cancellation",
      args: { p_idempotency_key: KEY, p_transfer_id: T1, p_reason: "refusé par la banque" },
    });
    expect(cancellationCall("confirm", "transfer", fields({ idempotency_key: KEY, transfer_id: T1 }))).toEqual({
      fn: "confirm_transfer_cancellation",
      args: { p_idempotency_key: KEY, p_transfer_id: T1 },
    });
    expect(cancellationCall("request", "file", fields({ idempotency_key: KEY, file_id: FILE, expected_version: "4", reason: "x", attestation: "other" }))).toEqual({
      error: "transfer_attestation_required",
    });
    expect(cancellationCall("request", "file", fields({ idempotency_key: KEY, file_id: FILE, expected_version: "4", attestation: "rejected_by_bank" }))).toEqual({
      error: "reason_required",
    });
    expect(cancellationCall("request", "transfer", fields({ idempotency_key: KEY, transfer_id: T1 }))).toEqual({ error: "reason_required" });
    expect(cancellationCall("confirm", "file", fields({ idempotency_key: KEY, file_id: FILE, expected_version: "v" }))).toEqual({ error: "unknown" });
    expect(cancellationCall("confirm", "transfer", fields({ idempotency_key: "k", transfer_id: T1 }))).toEqual({ error: "unknown" });
  });

  it("calls the client's rpc as a method (the client keeps its `this`)", async () => {
    const calls: unknown[] = [];
    const client = {
      tag: "client",
      rpc(this: { tag: string }, fn: string, args: unknown) {
        calls.push({ self: this.tag, fn, args });
        return Promise.resolve({ data: { status: "requested" }, error: null });
      },
    };
    const res = await cancellationRpc(client)("confirm_transfer_cancellation", { p_idempotency_key: KEY, p_transfer_id: T1 });
    expect(res).toEqual({ data: { status: "requested" }, error: null });
    expect(calls).toEqual([{ self: "client", fn: "confirm_transfer_cancellation", args: { p_idempotency_key: KEY, p_transfer_id: T1 } }]);
  });

  it("maps every refusal of the two steps to French (never the database's text)", () => {
    const cases: [string, string][] = [
      ["transfer file refused: no_statement_evidence", "transfer_no_statement_evidence"],
      ["transfer refused: no_statement_evidence", "transfer_no_statement_evidence"],
      ["transfer file refused: debit_seen", "transfer_debit_seen"],
      ["transfer file refused: same_person", "transfer_same_person"],
      ["transfer refused: same_person", "transfer_same_person"],
      ["transfer file refused: already_requested", "transfer_cancel_already_requested"],
      ["transfer refused: not_requested", "transfer_cancel_not_requested"],
      ["transfer file refused: holds_cancelled_transfer", "transfer_file_holds_cancelled"],
      // a downloaded file is never cancelled in one step
      ["transfer file refused: cancellation_request_required", "transfer_cancellation_request_required"],
      ["transfer refused: not_in_downloaded_file", "transfer_not_in_downloaded_file"],
      ["transfer file refused: not_live", "transfer_not_live"],
      ["transfer file refused: late_reason_too_long", "transfer_late_reason_too_long"],
      ["payee check refused: not_a_payout", "payee_check_not_a_payout"],
    ];
    for (const [message, code] of cases) {
      expect(transferErrorCode(message), message).toBe(code);
      expect(errorText(transferErrorCode(message))).not.toMatch(/refused|transfer/);
    }
    expect(errorText("transfer_same_person")).toContain("une autre personne");
    expect(errorText("transfer_no_statement_evidence")).toContain("jour ouvré suivant");
  });

  it("cancels a run's payout in a downloaded file first, then the run (money#2: payout_in_downloaded_file)", () => {
    expect(runCancelPath(null, null)).toBe("direct");
    expect(runCancelPath({ status: "ordered" }, null)).toBe("direct");
    expect(runCancelPath({ status: "in_file" }, { status: "generated", download_count: 0 })).toBe("direct");
    expect(runCancelPath({ status: "in_file" }, { status: "downloaded", download_count: 1 })).toBe("transfer_first");
    expect(runCancelPath({ status: "in_file" }, { status: "sent", download_count: 1 })).toBe("transfer_first");
    // cancelled under T1 (evidence, two people): the run is cancelled with no attestation
    expect(runCancelPath({ status: "cancelled" }, { status: "downloaded", download_count: 1 })).toBe("direct");
    expect(runCancelPath({ status: "booked" }, null)).toBe("none");
    expect(runErrorCode("remittance run refused: payout_in_downloaded_file")).toBe("run_payout_in_downloaded_file");
    expect(errorText("run_payout_in_downloaded_file")).toContain("confirmation d'une autre personne");
  });
});

describe("M2c-6a review T5: the payee check is cleared by a person with no part in the flagged IBAN (security#3)", () => {
  it("hides « Nom vérifié » from who recorded it, or proposed or confirmed the IBAN, and words the refusal", () => {
    expect(payeeCheckClearable({ recorded_by_me: false })).toBe(true);
    expect(payeeCheckClearable({ recorded_by_me: true })).toBe(false);
    expect(payeeCheckClearable({ recorded_by_me: false, can_clear: false })).toBe(false);
    expect(payeeCheckClearable({ recorded_by_me: false, can_clear: true })).toBe(true);
    expect(payeeCheckErrorCode("payee check refused: same_person")).toBe("payee_check_four_eyes");
    expect(payeeCheckErrorCode("payee check refused: four_eyes")).toBe("payee_check_four_eyes");
    expect(payeeCheckErrorCode("payee check refused: already_cleared")).toBe("payee_check_cleared");
    expect(errorText("payee_check_four_eyes")).toContain("ni celles qui ont proposé ou confirmé cet IBAN");
  });
});

describe("dates in Paris", () => {
  it("gives Paris's calendar day of an instant", () => {
    expect(parisDate(new Date("2026-11-11T22:30:00Z"))).toBe("2026-11-11");
    expect(parisDate(new Date("2026-11-11T23:30:00Z"))).toBe("2026-11-12");
    expect(parisDate(new Date("2026-07-01T22:30:00Z"))).toBe("2026-07-02");
  });
});
