import { expect, test, type Page } from "@playwright/test";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  adminClient,
  createConfirmedPayoutAccount,
  createMandate,
  createMember,
  createTenant,
  type Tenant,
} from "./support/admin";
import { camt053, camt053Lines, ibanFr, type Credit } from "./support/camt";
import { loginAsStaff, loginWithEmailCode } from "./support/session";
import { reviewShot } from "./screenshot";
import { expectOwnImport } from "./support/statements";

/**
 * M2c-7a (plan docs/design/m2c-7-plan.md §3.7, §3.9 E2E; ADR-0014 « M2c-7a »): a collection already remitted to the
 * client — its run's payout debited from the dedicated account — is « Désimputer »-ed: the sheet says it was already
 * paid to the client and that the servicer advances it (the sum is not taken from the client's other collections), the
 * page says the advance recorded, the run's page says the advance and why; an administrator's « Contrôles » find no
 * violation and offer « Vérification complète des avances ». « Couvrir » is shown on a planted result (a reversal of a
 * remitted entry left uncovered cannot be committed: LG009): the sentence names the amount, the client and the date,
 * and the command refuses — the advance exists. Screenshots `m2c7-desimputer-deja-reverse`, `m2c-controles`,
 * `m2c7-controles-couvrir` (mobile + desktop). The switch stays off. Synthetic data.
 *
 * M2c-7b (plan §4.3, §4.5 E2E): the sheet also says how the advance is recovered (no claw-back clause in this mandate:
 * a request); the run page words the advance with how it is recovered; « Avances » lists it (ops: no « Passer en
 * perte »), an administrator passes part of it as a loss with its evidence — the sheet states every effect, the page
 * then reads what is recovered and what is left; the Reversements page shows the chip « Avance à récupérer » while the
 * client's queue waits. Screenshots `m2c7-avances`, `m2c7-avance-perte`, `m2c7-reversements-avance` (mobile + desktop).
 */
const BANK_IBAN = ibanFr(616161);
const PAYOUT_IBAN = ibanFr(616162);
const FIXTURE = {
  name: "Créances à reverser.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-imputation.csv")),
};

let tenant: Tenant;

function parisToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
}

function addDays(isoDate: string, days: number): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

/** As remittances.spec.ts: the latest business day on or before yesterday (Paris). */
async function statementDay(): Promise<string> {
  const { data, error } = await adminClient()
    .from("business_calendar")
    .select("day")
    .eq("scope", "FR-conservative")
    .eq("closed", false)
    .lte("day", addDays(parisToday(), -1))
    .order("day", { ascending: false })
    .limit(1)
    .single();
  if (error) throw error;
  return data.day as string;
}

test.beforeAll(async () => {
  tenant = await createTenant();
  await createMandate(tenant);
  const { error } = await adminClient().from("bank_account").insert({
    organization_id: tenant.servicerId,
    iban: BANK_IBAN,
    currency: "EUR",
    label: "Fonds de tiers – Banque A",
    feed: "camt053",
    opened_on: "2026-01-01",
  });
  if (error) throw error;
  await createConfirmedPayoutAccount(tenant, PAYOUT_IBAN, "BOULANGERIE DURAND");
});

async function boardAndConfirm(page: Page) {
  await page.goto("/backoffice/reprises/nouveau");
  await page.getByLabel("Date d'arrêté du portefeuille").fill("2026-09-30");
  await page.getByLabel("Fichiers").setInputFiles(FIXTURE);
  await page.getByLabel("Encours restant dû à la date d'arrêté (€)").fill("4 800,00");
  await page.getByLabel("Nombre de lignes du fichier").fill("8");
  await page.getByRole("button", { name: "Déposer et analyser" }).click();
  const status = page.getByTestId("batch-status");
  await expect(status).toHaveText("Mapping à valider", { timeout: 60_000 });
  await page.getByRole("button", { name: "Valider le mapping" }).click();
  await expect(status).toHaveText("Prêt à intégrer", { timeout: 60_000 });
  await page.getByRole("button", { name: "Intégrer le lot" }).click();
  await expect(status).toHaveText("Intégré, à confirmer", { timeout: 60_000 });
  await page.getByRole("button", { name: "Confirmer le lot" }).click();
  await expect(status).toHaveText("Confirmé", { timeout: 60_000 });
}

async function rfOf(externalRef: string): Promise<string> {
  const admin = adminClient();
  const { data: account, error } = await admin
    .from("account")
    .select("id")
    .eq("portfolio_id", tenant.portfolioId)
    .eq("external_ref", externalRef)
    .single();
  if (error) throw error;
  const { data: ref } = await admin
    .from("payment_reference")
    .select("rf")
    .eq("account_id", account.id)
    .eq("status", "active")
    .single();
  return ref!.rf as string;
}

async function importStatement(page: Page, file: string, xml: string) {
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({
    name: file,
    mimeType: "application/xml",
    buffer: Buffer.from(xml, "utf-8"),
  });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  // (M2c-7b, the shared helper since 7c-1) this statement's own import, never the previous statement's « Importé »
  await expectOwnImport(page);
}

test("« Désimputer » a collection already remitted: the servicer's advance, the run page, « Contrôles »", async ({
  page,
  browser,
}, testInfo) => {
  test.setTimeout(300_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await boardAndConfirm(page);
  const day = await statementDay();
  const dayFr = day.split("-").reverse().join("/");
  const credits: Credit[] = [
    { ref: "AV-1", amountMinor: BigInt(50000), name: "DIALLO", iban: ibanFr(31), rf: await rfOf("C2929") },
  ];
  await importStatement(page, "releve-avance.xml", camt053(BANK_IBAN, day, credits));

  // the client's run: prepared (or prepared by the schedule), approved, its payout in a file, downloaded
  await page.goto("/backoffice/reversements");
  const waiting = page.getByTestId("prepare-row").filter({ hasText: tenant.clientName });
  const card = page.getByTestId("run-card").filter({ hasText: tenant.clientName });
  await expect(async () => {
    await page.reload();
    await expect(waiting.or(card)).toBeVisible({ timeout: 5_000 });
  }).toPass({ timeout: 90_000 });
  if (await waiting.isVisible()) {
    await waiting.getByRole("button", { name: "Préparer maintenant" }).click();
    await card.waitFor({ timeout: 15_000 }).catch(() => page.reload());
  }
  await expect(card.getByText("Brouillon", { exact: true })).toBeVisible({ timeout: 60_000 });
  await card.getByRole("link", { name: tenant.clientName }).click();
  await expect(page.getByTestId("run-status")).toHaveText("Brouillon");
  const runPage = page.url();
  await page.getByTestId("run-select").check();
  await page.getByTestId("approve-open").click();
  const sheet = page.getByTestId("approve-sheet");
  const lateReason = sheet.getByLabel(/Motif du retard/);
  if (await lateReason.isVisible()) await lateReason.fill("Encaissement identifié tardivement (E2E)");
  await sheet.getByTestId("approve-confirm").click();
  await expect(page.getByTestId("run-status")).toHaveText("Validé — virement ordonné", { timeout: 60_000 });

  await page.goto("/backoffice/reversements/virements");
  const account = page.getByTestId("paying-account").filter({ hasText: "Fonds de tiers – Banque A" });
  await account.getByTestId("generate-file").getByRole("button", { name: "Générer le fichier" }).click();
  await page
    .getByRole("dialog", { name: "Générer le fichier de virements" })
    .getByRole("button", { name: "Générer", exact: true })
    .click();
  const fileRow = account.getByTestId("file-row").first();
  await expect(fileRow.getByTestId("file-status")).toHaveText("Prêt à télécharger", { timeout: 60_000 });
  const [download] = await Promise.all([page.waitForEvent("download"), fileRow.getByTestId("file-download").click()]);
  const body = readFileSync(await download.path()).toString("utf-8");
  const e2e = body.match(/<EndToEndId>(RMT[0-9A-F]{12})<\/EndToEndId>/)![1];
  const sum = body.match(/<CtrlSum>(\d+)\.(\d{2})<\/CtrlSum>/)!;
  const payoutMinor = BigInt(sum[1]) * BigInt(100) + BigInt(sum[2]);
  // downloaded: the payout is in flight (the bank's debit books it; « Marquer comme transmis » is not needed for that)
  await expect(fileRow.getByTestId("file-mark-sent")).toBeVisible({ timeout: 15_000 });

  // the bank's debit of the payout: the debit job books it, the run is « Comptabilisé » (the collection is remitted)
  await importStatement(
    page,
    "releve-debit-avance.xml",
    camt053Lines(
      BANK_IBAN,
      day,
      [],
      [{ ref: "AV-DEBIT", amountMinor: payoutMinor, kind: "transfer", e2e, name: "BOULANGERIE DURAND" }],
      BigInt(50000),
    ),
  );
  await page.goto(runPage);
  await expect(async () => {
    await page.reload();
    await expect(page.getByTestId("run-status")).toHaveText("Comptabilisé", { timeout: 2_000 });
  }).toPass({ timeout: 60_000 });
  const runNumber = (await page.getByRole("heading", { level: 1 }).textContent())?.match(/RV-\d{4}-\d{6}/)?.[0];
  expect(runNumber).toBeTruthy();

  // « Désimputer » DIALLO's payment: the sheet says it was already paid to the client and the servicer advances it
  const { data: line, error } = await adminClient()
    .from("bank_transaction")
    .select("id")
    .eq("organization_id", tenant.servicerId)
    .eq("acct_svcr_ref", "AV-1")
    .single();
  if (error) throw error;
  const { data: payment } = await adminClient().from("payment").select("id").eq("bank_transaction_id", line.id).single();
  await page.goto(`/backoffice/encaissements/paiements/${payment!.id}`);
  await page.getByTestId("reverse-allocation").getByRole("button").first().click();
  const reverse = page.getByRole("dialog", { name: "Annuler cette imputation" });
  const remitted = reverse.getByTestId("sheet-remitted");
  await expect(remitted).toContainText(`Déjà reversé au client (reversement ${runNumber}, débité le ${dayFr}).`);
  await expect(remitted).toContainText(/En désimputant, le cabinet lui en fait l'avance \(500,00\s€\)/);
  await expect(remitted).toContainText("la somme n'est pas déduite de ses autres encaissements");
  // M2c-7b ([critic] L19 (d)): how it is recovered — this mandate has no claw-back clause
  await expect(remitted).toContainText("Une demande de remboursement pourra lui être adressée.");
  await reverse.getByLabel("Motif interne (non transmis au client)").fill("Paiement repris par la banque du débiteur (E2E)");
  await reviewShot(page, testInfo, "m2c7-desimputer-deja-reverse");
  await reverse.getByRole("button", { name: "Confirmer l'annulation" }).click();
  await expect(page.getByTestId("reverse-notice")).toContainText(
    /Imputation annulée ; avance du cabinet de 500,00\s€ enregistrée\./,
    { timeout: 15_000 },
  );
  await expect(page.getByTestId("payment-reason")).toHaveText("Imputation annulée");

  // the run's page: the advance recorded, and why
  await page.goto(runPage);
  await expect(page.getByTestId("run-payout-notes")).toContainText(
    // M2c-7b (plan §4.3): worded with how it is recovered (no claw-back clause: a request)
    /Avance du cabinet enregistrée le \d{2}\/\d{2}\/\d{4} \(encaissement de ce reversement annulé ou repris\) : 500,00\s€, à récupérer par une demande de remboursement \(pas de clause de reprise\)/,
  );
  // one advance: cause remitted_reversal, the line's amount (from the ledger, never computed here)
  const { data: advances } = await adminClient()
    .from("client_advance")
    .select("cause, amount_minor")
    .eq("client_organization_id", tenant.clientId);
  expect(advances).toEqual([{ cause: "remitted_reversal", amount_minor: 50000 }]);

  // « Contrôles », an administrator: the checks run now find no uncovered reversal and no advance off the books
  const use = testInfo.project.use;
  const context = await browser.newContext({
    baseURL: use.baseURL,
    viewport: use.viewport,
    userAgent: use.userAgent,
    deviceScaleFactor: use.deviceScaleFactor,
    isMobile: use.isMobile,
    hasTouch: use.hasTouch,
  });
  const admin = await context.newPage();
  await loginAsStaff(admin, await createMember(tenant.servicerId, "admin"));
  await admin.goto("/backoffice/encaissements/controles");
  const before = (await adminClient().from("payment_check_run").select("id").eq("organization_id", tenant.servicerId))
    .data?.length ?? 0;
  await admin.getByTestId("run-checks").getByRole("button", { name: "Lancer les contrôles" }).click();
  await expect
    .poll(
      async () => {
        const { data } = await adminClient()
          .from("payment_check_run")
          .select("id, finished_at")
          .eq("organization_id", tenant.servicerId);
        return (data ?? []).filter((r) => r.finished_at !== null).length;
      },
      { timeout: 60_000 },
    )
    .toBeGreaterThan(before);
  await admin.reload();
  for (const code of ["remitted_reversal_uncovered", "advance_ledger"])
    await expect(admin.locator(`[data-testid="check-row"][data-code="${code}"]`)).toHaveCount(0);
  await expect(admin.getByTestId("full-advance-check")).toContainText(
    "Les contrôles de chaque nuit relisent les annulations récentes ; le 1er du mois, ils relisent tous les reversements débités.",
  );
  await reviewShot(admin, testInfo, "m2c-controles");
  await admin.getByTestId("full-advance-check").getByRole("button", { name: "Vérification complète des avances" }).click();
  await expect(admin.getByTestId("full-advance-check-asked")).toHaveText(
    "Vérification complète demandée : elle passe avec les contrôles lancés maintenant.",
  );

  // « Couvrir », on a planted result (a check run written here, its one result naming the real reversal): the sentence,
  // then the command's refusal — the advance exists
  const { data: reversal } = await adminClient()
    .from("ledger_entry")
    .select("id")
    .eq("payment_id", payment!.id)
    .eq("entry_type", "reversal")
    .single();
  const run = randomUUID();
  const db = adminClient();
  const { error: e1 } = await db.from("payment_check_run").insert({ id: run, organization_id: tenant.servicerId });
  if (e1) throw e1;
  const { error: e2 } = await db.from("payment_check_result").insert({
    run_id: run,
    organization_id: tenant.servicerId,
    code: "remitted_reversal_uncovered",
    severity: "violation",
    subject_type: "ledger_entry",
    subject_id: reversal!.id,
    currency: "EUR",
    amount_minor: 50000,
    details: { client_id: tenant.clientId, recorded_on: parisToday(), target: 50000, held: 0 },
  });
  if (e2) throw e2;
  const { error: e3 } = await db
    .from("payment_check_run")
    .update({
      finished_at: new Date().toISOString(),
      violations: 1,
      alerts: 0,
      summary: { remitted_reversal_uncovered: 1 },
    })
    .eq("id", run);
  if (e3) throw e3;
  await admin.reload();
  const cover = admin.getByTestId("cover-reversal");
  const todayFr = parisToday().split("-").reverse().join("/");
  await expect(cover).toContainText(
    new RegExp(
      `Enregistrer l'avance du cabinet de 500,00\\s€ au client ${tenant.clientName} pour l'annulation du ${todayFr}`,
    ),
  );
  await reviewShot(admin, testInfo, "m2c7-controles-couvrir");
  await cover.getByRole("button", { name: "Couvrir" }).click();
  await expect(cover).toContainText("Rien à couvrir : l'avance existe déjà.");

  // M2c-7b « Avances »: the ops manager reads the advance (no claw-back clause: a request), and cannot pass it as a loss
  await page.goto("/backoffice/reversements/avances");
  const row = page.getByTestId("advance-row").filter({ hasText: tenant.clientName });
  await expect(row).toContainText("Paiement repris après reversement (dossier C2929)");
  await expect(row.getByTestId("advance-open")).toHaveText(/500,00\s€/);
  await expect(row.getByTestId("advance-recovery")).toContainText("Demande de remboursement (pas de clause de reprise)");
  await expect(row.getByTestId("write-off-open")).toHaveCount(0);
  // (review round 2) the advance's date is its birth (« Née le »)
  await expect(row.getByTestId("advance-born")).toContainText(/\d{2}\/\d{2}\/\d{4}/);
  await reviewShot(page, testInfo, "m2c7-avances");

  // the Reversements page: the chip « Avance à récupérer » on the client waiting (its queue: the reversal and the cover),
  // on its row of « Encaissements en attente » — or on its draft's card if the schedule prepared one meanwhile
  // (review round 1, tests-ui-4: never conditional)
  await page.goto("/backoffice/reversements");
  const holder = page
    .getByTestId("prepare-row")
    .filter({ hasText: tenant.clientName })
    .or(page.getByTestId("run-card").filter({ hasText: tenant.clientName }));
  await expect(holder.getByTestId("advance-chip")).toHaveText(/Avance à récupérer 500,00\s€/);
  await reviewShot(page, testInfo, "m2c7-reversements-avance");

  // (review round 1, tests-ui-6) the client space: its administrator reads what it still owes and how it is recovered
  const clientContext = await browser.newContext({
    baseURL: use.baseURL,
    viewport: use.viewport,
    userAgent: use.userAgent,
    deviceScaleFactor: use.deviceScaleFactor,
    isMobile: use.isMobile,
    hasTouch: use.hasTouch,
  });
  const client = await clientContext.newPage();
  await loginWithEmailCode(client, await createMember(tenant.clientId, "client_admin"));
  await expect(client).toHaveURL(/\/client$/);
  await client.goto("/client/reversements");
  const owed = client.getByTestId("client-advances");
  await expect(owed).toContainText(/Avances du cabinet à rembourser : 500,00\s€/);
  // (review round 2, advance-date-contradicts-barred) dated by its birth (« née le »), never by its recording alone
  await expect(owed).toContainText(
    /Avance née le \d{2}\/\d{2}\/\d{4} \(paiement repris après reversement\) : 500,00\s€ — une demande de remboursement pourra vous être adressée\./,
  );

  // an administrator passes 200,00 € of it as a loss, with its evidence: the sheet states every effect
  await admin.goto("/backoffice/reversements/avances");
  const adminRow = admin.getByTestId("advance-row").filter({ hasText: tenant.clientName });
  await adminRow.getByTestId("write-off-open").click();
  const lossSheet = admin.getByTestId("write-off-sheet");
  await lossSheet.getByLabel("Montant (€)").fill("200,00");
  await lossSheet.getByLabel("Motif (interne, non transmis au client)").fill("Créance déclarée irrécouvrable (E2E)");
  await lossSheet.getByLabel(/Pièce justificative/).setInputFiles({
    name: "decision.pdf",
    mimeType: "application/pdf",
    buffer: Buffer.from("%PDF-1.4\n% décision de passage en perte (E2E, synthétique)\n%%EOF\n", "utf-8"),
  });
  await expect(lossSheet.getByTestId("write-off-effect")).toHaveText(
    /Le cabinet enregistre une perte de 200,00\s€ \(compte 6780\)\. Collectoo ne réclame plus cette somme au client \(ni reprise, ni demande de remboursement\) ; rien ne lui est envoyé : ce n'est pas une remise de dette\. Irréversible\./,
  );
  await reviewShot(admin, testInfo, "m2c7-avance-perte");
  await lossSheet.getByTestId("write-off-confirm").click();
  await expect(admin.getByTestId("write-off-notice")).toContainText(
    "Avance passée en perte : Collectoo ne réclame plus cette somme au client.",
    { timeout: 15_000 },
  );
  const after = admin.getByTestId("advance-row").filter({ hasText: tenant.clientName });
  await expect(after.getByTestId("advance-open")).toHaveText(/300,00\s€/);
  // (review round 1, tests-ui-3; R3) what was passed as a loss apart from what was recovered (nothing yet)
  await expect(after.getByTestId("advance-recovered")).toHaveText(/^0,00\s€/);
  await expect(after.getByTestId("advance-written-off")).toHaveText(/200,00\s€ passés en perte/);
  await context.close();
  // the client space then: what is still claimed, never the loss (LEX-28: never « abandon » nor « remise »)
  await client.reload();
  await expect(owed).toContainText(/Avances du cabinet à rembourser : 300,00\s€/);
  await expect(owed).toContainText(/: 300,00\s€ — une demande de remboursement pourra vous être adressée\./);
  await expect(owed).not.toContainText(/abandon|remise|perte/i);
  await reviewShot(client, testInfo, "m2c7-client-avances");
  await clientContext.close();
  // the loss in the ledger, from the command (never computed here): 6780 / 4112 of 20 000, one write_off settlement
  const { data: settled } = await adminClient()
    .from("commission_settlement")
    .select("kind, amount_minor")
    .eq("client_organization_id", tenant.clientId)
    .eq("document_kind", "advance");
  expect(settled).toEqual([{ kind: "write_off", amount_minor: 20000 }]);
  const { data: still } = await adminClient()
    .from("client_advance")
    .select("cause, amount_minor")
    .eq("client_organization_id", tenant.clientId);
  expect(still).toEqual([{ cause: "remitted_reversal", amount_minor: 50000 }]);
});
