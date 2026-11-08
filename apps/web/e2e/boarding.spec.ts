import { expect, test } from "@playwright/test";
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
 * report): 40 rows, 244 493,04 €.
 */
const FIXTURE = path.resolve(__dirname, "fixtures/factures-b2b.csv");

let tenant: Tenant;

test.beforeAll(async () => {
  tenant = await createTenant();
  await createMandate(tenant);
});

test("ops board a client file: upload, mapping review, quality report, commit, confirm", async ({ page }, testInfo) => {
  test.setTimeout(180_000);
  await loginAsStaff(page, await createMember(tenant.servicerId, "ops_manager"));

  await page.getByTestId("boarding-link").click();
  await expect(page).toHaveURL(/\/backoffice\/reprises$/);
  await page.getByRole("link", { name: "Nouveau lot" }).click();
  await page.getByLabel("Fichiers").setInputFiles(FIXTURE);
  await page.getByLabel("Montant total (€)").fill("244 493,04");
  await page.getByLabel("Nombre de lignes").fill("40");
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
  await expect(quality.getByTestId("dq-reconciliation")).toContainText("concordants au centime");
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
