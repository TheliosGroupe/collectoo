import { expect, test, type Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { createMandate, createMember, createTenant, type Tenant } from "./support/admin";
import { loginAsStaff } from "./support/session";
import { reviewShot } from "./screenshot";

/**
 * M1-19: a synthetic B2B invoice file boarded end to end through the back-office, with the
 * boarding worker consuming the queue (mock LLM, mock addresses).
 *
 * Fixture: 40 synthetic invoices from `generate_civil("b2b_invoice", "fr_semicolon", 40, 7,
 * defect_rate=0)` plus an unmapped "Code vendeur" column. Its totals (from the worker's DQ
 * report): 40 rows, 244 493,04 € of invoices, 212 186,29 € still outstanding.
 * Uploaded under an accented name: storage keys are built from ids, not from the name.
 */
const FIXTURE = {
  name: "Créances août 2026.csv",
  mimeType: "text/csv",
  buffer: readFileSync(path.resolve(__dirname, "fixtures/factures-b2b.csv")),
};

async function uploadFixture(page: Page) {
  await page.getByTestId("boarding-link").click();
  await expect(page).toHaveURL(/\/backoffice\/reprises$/);
  await page.getByRole("link", { name: "Nouveau lot" }).click();
  await page.getByLabel("Date d'arrêté du portefeuille").fill("2026-09-30");
  await page.getByLabel("Fichiers").setInputFiles(FIXTURE);
}

let tenant: Tenant;

test.beforeAll(async () => {
  tenant = await createTenant();
  await createMandate(tenant);
});

test("ops board a client file: upload, mapping review, quality report, commit, confirm", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));

  await uploadFixture(page);
  await page.getByLabel("Encours restant dû à la date d'arrêté (€)").fill("212 186,29");
  await page.getByLabel("Nombre de lignes du fichier").fill("40");
  await reviewShot(page, testInfo, "m1-boarding-upload");
  await page.getByRole("button", { name: "Déposer et analyser" }).click();

  // The worker profiles the file and proposes the mapping.
  await expect(page).toHaveURL(/\/backoffice\/reprises\/[0-9a-f-]{36}$/, { timeout: 30_000 });
  const status = page.getByTestId("batch-status");
  await expect(status).toHaveText("Mapping à valider", { timeout: 60_000 });
  await expect(page.getByTestId("proposal")).toHaveCount(18);
  const amount = page.getByTestId("proposal").filter({ hasText: "Montant TTC" });
  await expect(amount.getByRole("combobox")).toHaveValue("claim_item.amount");
  const seller = page.getByTestId("proposal").filter({ hasText: "Code vendeur" });
  await expect(seller.getByRole("combobox")).toHaveValue("");
  await reviewShot(page, testInfo, "m1-boarding-mapping");

  await page.getByRole("button", { name: "Valider le mapping" }).click();
  await expect(status).toHaveText("Prêt à intégrer", { timeout: 60_000 });
  const quality = page.getByTestId("quality");
  await expect(quality.getByTestId("dq-rows")).toHaveText("40");
  await expect(quality.getByTestId("dq-blocking")).toHaveText("0");
  await expect(quality.getByTestId("dq-total")).toHaveText("244 493,04 €");
  await expect(quality.getByTestId("dq-outstanding")).toHaveText("212 186,29 €");
  await expect(quality.getByTestId("dq-reconciliation")).toContainText("Encours concordant au centime, lignes concordantes");
  await expect(page.getByTestId("files")).toContainText("Créances août 2026.csv");
  await reviewShot(page, testInfo, "m1-boarding-quality");

  await page.getByRole("button", { name: "Intégrer le lot" }).click();
  await expect(status).toHaveText("Intégré, à confirmer");
  await reviewShot(page, testInfo, "m1-boarding-committed");

  await page.getByRole("button", { name: "Confirmer le lot" }).click();
  await expect(status).toHaveText("Confirmé");
  await expect(page.getByTestId("history")).toContainText("Confirmé");

  await page.getByRole("link", { name: "Reprises" }).click();
  await expect(page.getByTestId("batch-list")).toContainText(tenant.clientName);
  await expect(page.getByTestId("batch-list")).toContainText("Confirmé");
  await reviewShot(page, testInfo, "m1-boarding-list");
});

test("ops abandon a batch before integrating it", async ({ page }) => {
  test.setTimeout(120_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));
  await uploadFixture(page);
  await page.getByRole("button", { name: "Déposer et analyser" }).click();
  const status = page.getByTestId("batch-status");
  await expect(status).toHaveText("Mapping à valider", { timeout: 60_000 });

  await page.getByTestId("abandon").getByText("Abandonner ce lot").click();
  await page.getByLabel("Motif de l'abandon").fill("Mauvais portefeuille");
  await page.getByRole("button", { name: "Abandonner le lot" }).click();
  await expect(status).toHaveText("Abandonné");
  await expect(page.getByTestId("mapping").getByRole("combobox").first()).toHaveCount(0);
  await expect(page.getByTestId("history")).toContainText("Abandonné");
});
