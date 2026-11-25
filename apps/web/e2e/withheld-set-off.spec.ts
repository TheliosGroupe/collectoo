import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { adminClient, createConfirmedPayoutAccount, createMandate, createMember, createTenant, type Tenant } from "./support/admin";
import { camt053, camt053Lines, ibanFr, type Credit } from "./support/camt";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";
import { expectOwnImport } from "./support/statements";

/**
 * M2c-7d-3 (plan docs/design/m2c-7-plan.md §6.2.8, §6.3, §6.6; ADR-0014 « M2c-7d-3 », carried item 3 — the walk 7d-2's
 * review left open, TUI-8): a client's run sets its own invoice off; its file is downloaded; a redressement is recorded
 * (effective after the collection: the invoice was born before the opening); the payout's debit is imported — the debit
 * job withholds the set-off, the run's page says « Compensation retenue au débit » and why; the next run gives it back and
 * its statement is drawn under `releve-reversement-fr-4` with the withheld row; a liquidation recorded then holds that
 * run's payout on « Virements » (« Virement bloqué — Client en liquidation : compte du liquidateur à confirmer … »);
 * « Contrôles » lists the invoice to declare. Screenshots `m2c7-compensation-retenue`, `m2c7-controles-creances-a-declarer` (mobile + desktop).
 * Review round 1 (TUI-6): the next run's drawn statement — its PDF drawn by fr-4, its CSV's withheld row (the row's wording
 * in the PDF is the renderer's, pinned by the worker's fr-4 golden: the PDF's text is font-encoded) —; and 7d-2's own hold
 * on « Virements » (client_status_changed): a run approved with its set-off, a redressement recorded before its file is
 * generated (an opening blocks no payout) — screenshot `m2c7-virement-situation-changee` (mobile + desktop).
 * Each test its own tenant (the tests run in parallel). The switch stays off. Synthetic data.
 */
const BANK_IBAN = ibanFr(727271);
const PAYOUT_IBAN = ibanFr(727272);
const FIXTURE = {
  name: "Créances du client.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-imputation.csv")),
};
const PDF = (text: string) => ({ name: `${text}.pdf`, mimeType: "application/pdf", buffer: Buffer.from(`%PDF-1.4\n% ${text}\n%%EOF\n`) });

let tenant: Tenant;

function parisToday(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
}

function addDays(isoDate: string, days: number): string {
  const [y, m, d] = isoDate.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

/** The two latest business days on or before yesterday (Paris): [the earlier, the later]. */
async function lastTwoBusinessDays(): Promise<[string, string]> {
  const { data, error } = await adminClient()
    .from("business_calendar")
    .select("day")
    .eq("scope", "FR-conservative")
    .eq("closed", false)
    .lte("day", addDays(parisToday(), -1))
    .order("day", { ascending: false })
    .limit(2);
  if (error) throw error;
  return [data[1].day as string, data[0].day as string];
}

/** A tenant of its own: its mandate (netting clause), its dedicated account, the client's confirmed payout account. */
async function setupTenant(): Promise<Tenant> {
  const t = await createTenant();
  await createMandate(t);
  const { error } = await adminClient().from("bank_account").insert({
    organization_id: t.servicerId,
    iban: BANK_IBAN,
    currency: "EUR",
    label: "Fonds de tiers – Banque A",
    feed: "camt053",
    opened_on: "2026-01-01",
  });
  if (error) throw error;
  await createConfirmedPayoutAccount(t, PAYOUT_IBAN, t.clientName.toUpperCase());
  return t;
}

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
  const { data: ref } = await admin.from("payment_reference").select("rf").eq("account_id", account.id).eq("status", "active").single();
  return ref!.rf as string;
}

async function importStatement(page: Page, file: string, xml: string) {
  await page.goto("/backoffice/encaissements");
  const form = page.getByTestId("statement-upload");
  await form.getByLabel("Relevé CAMT.053 (XML)").setInputFiles({ name: file, mimeType: "application/xml", buffer: Buffer.from(xml, "utf-8") });
  await form.getByRole("button", { name: "Importer le relevé" }).click();
  await expectOwnImport(page);
}

async function joinDocument(page: Page, kind: string, file: string) {
  const upload = page.getByTestId("client-document-upload");
  const details = page.getByTestId("client-documents").locator("details").filter({ has: upload });
  if (!(await upload.isVisible())) await details.locator("summary").click();
  await upload.getByLabel("Type de document").selectOption(kind);
  await upload.getByLabel(/^Fichier/).setInputFiles(PDF(file));
  await upload.getByRole("button", { name: "Joindre le document" }).click();
  await expect(page.getByTestId("client-document").filter({ hasText: `${file}.pdf` })).toBeVisible();
}

/** « Enregistrer un événement » on the client's page, with its evidence joined first. */
async function recordEvent(page: Page, kind: string, day: string, evidence: string, publication?: string) {
  await page.goto(`/backoffice/clients/${tenant.clientId}/reversement`);
  await joinDocument(page, "client_status_evidence", evidence);
  const events = page.getByTestId("client-events");
  const form = page.getByTestId("record-event-form");
  if (!(await form.isVisible())) await events.getByText("Enregistrer un événement").click();
  await form.getByRole("combobox", { name: "Événement", exact: true }).selectOption(kind);
  await form.getByLabel("Date d'effet").fill(day);
  await form.getByLabel("Justificatif").selectOption({ label: `${evidence}.pdf` });
  if (publication) await form.getByLabel(/Date de publication au BODACC/).fill(publication);
  // (review round 3) wait for this event's own row: an earlier event recorded today already shows the day (« enregistré
  // le … »), so a row matching the date alone could be found before this one is committed (the full run under load
  // went to « Virements » before the liquidation was recorded)
  const rows = events.getByTestId("client-event");
  const before = await rows.count();
  await form.getByRole("button", { name: "Enregistrer l'événement" }).click();
  await expect(rows).toHaveCount(before + 1);
  await expect(rows.filter({ hasText: new RegExp(`^${day.split("-").reverse().join("/")} · `) }).first()).toBeVisible();
}

/** The client's draft on « Reversements » (prepared now when it waits), opened and approved; its page's URL. */
async function prepareAndApprove(page: Page): Promise<string> {
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
  await page.waitForURL(/\/backoffice\/reversements\/[0-9a-f-]{36}$/);
  const runPage = page.url();
  await expect(page.getByTestId("run-status")).toHaveText("Brouillon");
  await page.getByTestId("run-select").check();
  await page.getByTestId("approve-open").click();
  const sheet = page.getByTestId("approve-sheet");
  const lateReason = sheet.getByLabel(/Motif du retard/);
  if (await lateReason.isVisible()) await lateReason.fill("Encaissement identifié tardivement (E2E)");
  await sheet.getByTestId("approve-confirm").click();
  await expect(page.getByTestId("run-status")).toHaveText(/Validé|Comptabilisé/, { timeout: 60_000 });
  return runPage;
}

test("a set-off withheld at the debit after a redressement: the run page, the statement fr-4, the hold, « Contrôles »", async ({
  page,
}, testInfo) => {
  test.setTimeout(480_000);
  tenant = await setupTenant();
  await loginAsStaff(page, await createMember(tenant.servicerId, "admin"));
  await boardAndConfirm(page);
  const [collected, opening] = await lastTwoBusinessDays();
  const openingFr = opening.split("-").reverse().join("/");
  const credits: Credit[] = [{ ref: "WS-1", amountMinor: BigInt(50000), name: "DIALLO", iban: ibanFr(51), rf: await rfOf("C2929") }];
  await importStatement(page, "releve-compensation.xml", camt053(BANK_IBAN, collected, credits));

  // RV-1: its own invoice set off on its payout; the payout in a file, downloaded
  const runPage = await prepareAndApprove(page);
  const runNumber = (await page.getByRole("heading", { level: 1 }).textContent())?.match(/RV-\d{4}-\d{6}/)?.[0];
  expect(runNumber).toBeTruthy();
  await page.goto("/backoffice/reversements/virements");
  const account = page.getByTestId("paying-account").filter({ hasText: "Fonds de tiers – Banque A" });
  await account.getByTestId("generate-file").getByRole("button", { name: "Générer le fichier" }).click();
  await page.getByRole("dialog", { name: "Générer le fichier de virements" }).getByRole("button", { name: "Générer", exact: true }).click();
  const fileRow = account.getByTestId("file-row").first();
  await expect(fileRow.getByTestId("file-status")).toHaveText("Prêt à télécharger", { timeout: 60_000 });
  const [download] = await Promise.all([page.waitForEvent("download"), fileRow.getByTestId("file-download").click()]);
  const body = readFileSync(await download.path()).toString("utf-8");
  const e2e = body.match(/<EndToEndId>(RMT[0-9A-F]{12})<\/EndToEndId>/)![1];
  const amount = body.match(/<InstdAmt Ccy="EUR">(\d+)\.(\d{2})<\/InstdAmt>/)!;
  const payoutMinor = BigInt(amount[1]) * BigInt(100) + BigInt(amount[2]);

  // the redressement, recorded after the download (effective the day after the collection, published that day)
  await recordEvent(page, "proceeding_opened", opening, "Jugement-RJ", opening);

  // the payout's debit: the debit job withholds the set-off of the invoice born before the opening
  await importStatement(
    page,
    "releve-debit-compensation.xml",
    camt053Lines(BANK_IBAN, opening, [], [{ ref: "WS-DEBIT", amountMinor: payoutMinor, kind: "transfer", e2e, name: "DIALLO" }], BigInt(50000)),
  );
  await page.goto(runPage);
  await expect(async () => {
    await page.reload();
    await expect(page.getByTestId("run-status")).toHaveText("Comptabilisé", { timeout: 2_000 });
  }).toPass({ timeout: 60_000 });
  const withheld = page.getByTestId("run-withheld-notes");
  await expect(withheld).toContainText(
    new RegExp(`Compensation retenue au débit le ${openingFr.replace(/\//g, "\\/")} : [\\d\\s,]+\\s€ \\(factures [\\d\\s,]+\\s€\\) — procédure collective depuis le ${openingFr.replace(/\//g, "\\/")} \\(règle du cabinet\\)`),
  );
  await expect(withheld).toContainText("à rendre au client par le prochain reversement");
  await reviewShot(page, testInfo, "m2c7-compensation-retenue");

  // RV-2 gives it back: its statement is drawn under fr-4 and names the withheld run
  await prepareAndApprove(page);
  await expect(page.getByTestId("run-lines")).toContainText("Compensation retenue au débit, rendue");
  const { data: runs } = await adminClient()
    .from("remittance_run")
    .select("id, number")
    .eq("client_organization_id", tenant.clientId)
    .neq("number", runNumber!)
    .neq("status", "cancelled");
  const second = runs!.find((r) => r.number !== runNumber)!;
  await expect
    .poll(
      async () =>
        (await adminClient().from("remittance_statement").select("template_version").eq("run_id", second.id).maybeSingle()).data
          ?.template_version,
      { timeout: 60_000 },
    )
    .toBe("releve-reversement-fr-4");
  const { data: statement } = await adminClient().from("remittance_statement").select("payload").eq("run_id", second.id).single();
  const rows = (statement!.payload as { withheld_given_back: { run_number: string; withheld_on: string }[] }).withheld_given_back;
  expect(rows.map((r) => [r.run_number, r.withheld_on])).toEqual([[runNumber, opening]]);
  // review round 1 (TUI-6): the statement as drawn and downloaded from the run's page — its PDF by fr-4, its CSV's row
  await expect(async () => {
    await page.reload();
    await expect(page.getByTestId("run-statement-pdf")).toBeVisible({ timeout: 2_000 });
  }).toPass({ timeout: 60_000 });
  const pdf = await page.request.get((await page.getByTestId("run-statement-pdf").getAttribute("href"))!);
  expect(pdf.status()).toBe(200);
  const pdfBytes = await pdf.body();
  expect(pdfBytes.subarray(0, 5).toString()).toBe("%PDF-");
  expect(pdfBytes.includes("releve-reversement-fr-4")).toBe(true);
  const csv = await page.request.get((await page.getByTestId("run-statement-csv").getAttribute("href"))!);
  expect(csv.status()).toBe(200);
  expect((await csv.body()).toString("utf-8")).toContain("Compensation retenue au débit, rendue");

  // a liquidation recorded now: RV-2's payout, prepared under the redressement, is held — its payee is now the
  // liquidator, whose account is not confirmed
  await recordEvent(page, "liquidation", parisToday(), "Jugement-LJ");
  await page.goto("/backoffice/reversements/virements");
  await expect(
    page.getByText(
      "Virement bloqué — Client en liquidation : compte du liquidateur à confirmer, avec le jugement qui le nomme (second administrateur)",
    ),
  ).toBeVisible({ timeout: 30_000 });

  // « Contrôles »: RV-1's invoice, born before the opening and still open, is to declare
  await page.goto("/backoffice/encaissements/controles");
  const before = (await adminClient().from("payment_check_run").select("id").eq("organization_id", tenant.servicerId)).data?.length ?? 0;
  await page.getByTestId("run-checks").getByRole("button", { name: "Lancer les contrôles" }).click();
  await expect
    .poll(
      async () => {
        const { data } = await adminClient().from("payment_check_run").select("id, finished_at").eq("organization_id", tenant.servicerId);
        return (data ?? []).filter((r) => r.finished_at !== null).length;
      },
      { timeout: 60_000 },
    )
    .toBeGreaterThan(before);
  await page.reload();
  const claim = page.locator('[data-testid="check-row"][data-code="claims_to_declare"]');
  await expect(claim).toHaveCount(1);
  await expect(claim).toContainText("Créance du cabinet à déclarer");
  await expect(claim).toContainText(/Facture FC-\d{4}-\d{6} à déclarer au liquidateur au plus tard le \d{2}\/\d{2}\/\d{4} \(deux mois après la publication du jugement au BODACC le/);
  await reviewShot(page, testInfo, "m2c7-controles-creances-a-declarer");
});

// review round 1 (TUI-6): 7d-2's « Virements » hold for this flow — the run's frozen set-off no longer holds once the
// redressement is recorded (its own invoice was born before the opening), its file not yet generated
test("a redressement recorded after a run's approval, before its file: « Virements » holds the payout (client_status_changed)", async ({
  page,
}, testInfo) => {
  test.setTimeout(300_000);
  tenant = await setupTenant();
  await loginAsStaff(page, await createMember(tenant.servicerId, "admin"));
  await boardAndConfirm(page);
  const [collected, opening] = await lastTwoBusinessDays();
  const credits: Credit[] = [{ ref: "WC-1", amountMinor: BigInt(50000), name: "DIALLO", iban: ibanFr(52), rf: await rfOf("C2929") }];
  await importStatement(page, "releve-situation.xml", camt053(BANK_IBAN, collected, credits));
  await prepareAndApprove(page);
  await recordEvent(page, "proceeding_opened", opening, "Jugement-RJ", opening);
  await page.goto("/backoffice/reversements/virements");
  const row = page.getByTestId("transfer-row").filter({ hasText: tenant.clientName });
  await expect(row.getByTestId("transfer-hold")).toHaveText(
    "La situation du client a changé depuis la préparation (procédure collective, liquidation, fin du mandat ou saisie) : ce reversement compense ce qui ne peut plus l'être. Annulez le reversement et préparez-en un nouveau",
    { timeout: 30_000 },
  );
  await reviewShot(page, testInfo, "m2c7-virement-situation-changee");
});
